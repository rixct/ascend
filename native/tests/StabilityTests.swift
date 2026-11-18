import AppKit
import Foundation

extension Notification.Name { static let ascendSave = Notification.Name("dev.ascend.save") }

private final class WeakReference<T: AnyObject> {
  weak var value: T?
  init(_ value: T?) { self.value = value }
}

@main struct StabilityTests {
  static func main() {
    // AppKit calls in this process must see a real main run loop. Without it, CI's
    // macOS runner hits a libdispatch queue check and the test dies with SIGTRAP.
    NSApplication.shared.setActivationPolicy(.prohibited)
    Task { @MainActor in
      do {
        try await run()
        fflush(stdout)
        exit(0)
      } catch {
        fputs("StabilityTests failed: \(error)\n", stderr)
        fflush(stderr)
        exit(1)
      }
    }
    NSApplication.shared.run()
  }
  @MainActor static func request(_ engine: EngineProcess, _ payload: [String: Any]) async -> Result<
    Response, Error
  > {
    await withCheckedContinuation { continuation in
      engine.send(payload) { continuation.resume(returning: $0) }
    }
  }
  private static func fail(_ message: String) -> Never {
    fputs("StabilityTests: \(message)\n", stderr)
    fflush(stderr)
    exit(1)
  }
  private static func require(_ condition: Bool, _ message: String) {
    if !condition { fail(message) }
  }
  private static func mark(_ name: String) {
    fputs("stage \(name)\n", stderr)
    fflush(stderr)
  }
  private static func waitReleased<T: AnyObject>(_ ref: WeakReference<T>, _ message: String) async throws {
    for _ in 0..<250 {
      if ref.value == nil { return }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    require(false, message)
  }
  @MainActor static func run() async throws {
    mark("start")
    let args = CommandLine.arguments
    let python = URL(fileURLWithPath: args[1])
    let fixture = args[2]
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    mark("failures")
    for mode in ["hang", "partial", "oversized", "malformed", "exit", "blocked_write"] {
      let engine = try EngineProcess(
        executableURL: python, arguments: [fixture, mode, "-"], timeout: 0.5, maxResponseBytes: 1024
      )
      let started = ProcessInfo.processInfo.systemUptime
      let result = await request(
        engine,
        [
          "command": "load",
          "text": mode == "blocked_write" ? String(repeating: "x", count: 2_000_000) : "",
        ])
      if case .failure = result {} else { require(false, "Expected bounded failure for \(mode)") }
      require(ProcessInfo.processInfo.systemUptime - started < 8, "Unbounded pipe wait: \(mode)")
      engine.shutdown()
    }
    mark("healthy")
    let healthy = try EngineProcess(executableURL: python, arguments: [fixture, "slow", "-"])
    if case .failure = await request(healthy, ["command": "settings", "value": Double.nan]) {} else {
      require(false, "Non-finite values must fail before writing to the pipe")
    }
    if case .success = await request(healthy, ["command": "load"]) {} else {
      require(false, "Invalid form values must not shut down a healthy engine")
    }
    healthy.shutdown()

    // Cancellation wakes a blocked read, without blocking the main actor or leaking its owner.
    var transport: EngineProcess? = try EngineProcess(
      executableURL: python, arguments: [fixture, "hang", "-"], timeout: 30)
    let releasedTransport = WeakReference(transport)
    let cancellation = Task { @MainActor [engine = transport!] in
      await request(engine, ["command": "load"])
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    transport?.shutdown()
    transport = nil
    if case .failure = await cancellation.value {} else {
      require(false, "Cancellation did not reach pending read")
    }
    try await waitReleased(releasedTransport, "IPC transport retained after cancellation")

    mark("deferred")
    var deferredStore: Store? = Store(startMonitoring: false)
    let releasedDeferredStore = WeakReference(deferredStore)
    deferredStore = nil
    try await waitReleased(releasedDeferredStore, "Deferred startup retained an unused Store")

    mark("notes")
    let log = directory.appendingPathComponent("commands.jsonl")
    var store: Store? = Store(
      engine: try EngineProcess(executableURL: python, arguments: [fixture, "slow", log.path]),
      startMonitoring: false)
    let releasedStore = WeakReference(store)
    for index in 0..<10_000 { store?.send("notes", ["text": "note \(index)"]) }
    var finalAction = false
    store?.send("backup") { finalAction = true }
    require(store?.busy == true, "Backup did not mark the store busy")
    for _ in 0..<500 {
      if finalAction { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    require(finalAction && store?.busy == false, "Queue did not finish in order")
    let commands = try String(contentsOf: log).split(separator: "\n").map {
      try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }
    require(commands.count == 3, "Keystrokes created an unbounded IPC backlog")
    require(commands[1]["text"] as? String == "note 9999", "Latest note was not the one sent")
    require(commands[2]["command"] as? String == "backup", "Backup did not follow the coalesced note")
    store?.cancelImport()
    var importConfirmed = false
    store?.send("confirm_import") { importConfirmed = true }
    for _ in 0..<500 {
      if importConfirmed { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    require(importConfirmed, "Import confirmation did not reach the engine")
    let importLog = try String(contentsOf: log)
    require(
      !importLog.contains("cancel_import"), "Dismissal cancelled Replace before its action")
    store?.cancelImport()
    var cancelDelivered = false
    for _ in 0..<500 {
      cancelDelivered = try String(contentsOf: log).contains("cancel_import")
      if cancelDelivered { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    require(cancelDelivered, "Explicit cancel did not reach the engine")
    store?.skillSelection = ["one", "two", "three"]
    store?.deleteSelectedSkills()
    for _ in 0..<500 {
      if store?.skillSelection.isEmpty == true { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    require(store?.skillSelection.isEmpty == true, "Skill deletion did not clear the selection")
    store = nil
    try await waitReleased(releasedStore, "Store retained after recursive skill deletion")

    mark("presence")
    let presenceLog = directory.appendingPathComponent("presence.jsonl")
    var presenceStore: Store? = Store(
      engine: try EngineProcess(executableURL: python, arguments: [fixture, "slow", presenceLog.path]),
      startMonitoring: false)
    let releasedPresenceStore = WeakReference(presenceStore)
    for index in 0..<10_000 {
      presenceStore?.send("presence", ["id": "session", "present": index < 9999, "observed_at_ms": index])
    }
    var presenceFinished = false
    presenceStore?.send("backup") { presenceFinished = true }
    for _ in 0..<500 {
      if presenceFinished { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    require(presenceFinished, "Presence queue did not finish")
    let presenceCommands = try String(contentsOf: presenceLog).split(separator: "\n").map {
      try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }
    require(presenceCommands.count == 3, "Presence created an unbounded IPC backlog")
    require(presenceCommands[1]["present"] as? Bool == false, "A queued positive replaced the latest absence")
    require(presenceCommands[1]["observed_at_ms"] as? Int == 9999, "Latest presence observation was dropped")
    presenceStore = nil
    try await waitReleased(releasedPresenceStore, "Presence callback retained the Store")

    mark("exit")
    let exitLog = directory.appendingPathComponent("exit.jsonl")
    var exitStore: Store? = Store(
      engine: try EngineProcess(
        executableURL: python,
        arguments: [fixture, "slow", exitLog.path]), startMonitoring: false)
    let releasedExitStore = WeakReference(exitStore)
    for index in 0..<10_000 { exitStore?.send("notes", ["text": "exit note \(index)"]) }
    await withCheckedContinuation { continuation in
      exitStore?.prepareToTerminate { continuation.resume() }
    }
    let saved = try String(contentsOf: exitLog)
    require(saved.contains("exit note 9999"), "Termination lost the coalesced draft")
    exitStore = nil
    try await waitReleased(releasedExitStore, "Termination retained the Store")

    mark("focus")
    // Browser automation must not strand utility threads or accumulate blocked pipes.
    let browserCases: [(String, FocusSiteObservation)] = [
      ("focus_ok", .observed("example.com")), ("focus_long_url", .observed("example.com")),
      ("focus_blank", .observed(nil)), ("focus_failed", .unavailable),
      ("focus_flood", .unavailable), ("focus_stubborn", .unavailable),
    ]
    for (mode, expected) in browserCases {
      let started = ProcessInfo.processInfo.systemUptime
      let observation = await withCheckedContinuation { continuation in
        FocusBrowser.readOutput(executable: python, arguments: [fixture, mode, "-"], timeout: 0.3) {
          continuation.resume(returning: $0)
        }
      }
      require(observation == expected, "Unexpected browser result for \(mode)")
      require(ProcessInfo.processInfo.systemUptime - started < 8, "Browser query hung: \(mode)")
    }
    var browser = "com.apple.Safari"
    var uptime: TimeInterval = 100
    var browserReply: ((FocusSiteObservation) -> Void)?
    var reportedSite: FocusSiteObservation?
    let reporter = FocusReporter(currentBundle: { browser }, now: { uptime }, readHost: { _, reply in browserReply = reply })
    reporter.onReport = { _, site in reportedSite = site }
    reporter.sample(readSite: true)
    require(reportedSite == .unavailable, "A pending browser query was reported as observed")
    browserReply?(.observed("example.com"))
    require(reportedSite == .observed("example.com"), "Focus report did not record the site")
    reporter.sample(readSite: true)
    browserReply?(.unavailable)
    require(reportedSite == .unavailable, "A failed browser query retained the known site")
    reporter.sample(readSite: true)
    browserReply?(.observed(nil))
    require(reportedSite == .observed(nil), "A blank browser tab was reported as unavailable")
    uptime += 2.1
    reporter.sample(readSite: true)
    require(reportedSite == .unavailable, "Expired browser observations kept authorizing focus")
    uptime += 2.1
    browserReply?(.observed("example.com"))
    require(reportedSite == .unavailable, "A delayed browser response authorized stale focus")
    reporter.sample(readSite: true)
    browser = "com.apple.TextEdit"
    browserReply?(.observed("example.com"))
    require(reportedSite == .unavailable, "A browser response outlived the frontmost application")
    reporter.sample(readSite: true)
    require(reportedSite == .observed(nil), "A non-browser app unexpectedly needed a tab check")
    reporter.stop()
    browser = "com.apple.Safari"
    browserReply = nil
    reporter.sample(readSite: true, skipSiteFor: [browser])
    require(browserReply == nil && reportedSite == .observed(nil), "A listed browser triggered a tab check")

    mark("scoped")
    let scopedLog = directory.appendingPathComponent("scoped-notes.jsonl")
    let scopedStore = Store(engine: try EngineProcess(executableURL: python, arguments: [fixture, "slow", scopedLog.path]), startMonitoring: false)
    scopedStore.send("notes", ["id": "first", "text": "first draft"])
    scopedStore.send("notes", ["id": "second", "text": "second draft"])
    var scopedFinished = false
    scopedStore.send("backup") { scopedFinished = true }
    for _ in 0..<500 {
      if scopedFinished { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let scopedCommands = try String(contentsOf: scopedLog)
    require(scopedCommands.contains("first draft") && scopedCommands.contains("second draft"), "Note coalescing crossed session boundaries")
    var importFinished = false
    scopedStore.send("confirm_import") { importFinished = true }
    for _ in 0..<500 {
      if importFinished { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    require(importFinished && scopedStore.profileGeneration == 1, "Import did not invalidate profile drafts")
    scopedStore.shutdown()

    mark("avatar")
    let png = try Data(contentsOf: URL(fileURLWithPath: args[3])).base64EncodedString()
    let cache = AvatarImages()
    guard let image = cache.image(for: png) else {
      fail("Avatar fixture did not decode")
    }
    for _ in 0..<10_000 {
      autoreleasepool { require(cache.image(for: png) === image, "Avatar cache allocated a new image") }
    }
    guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      fail("Avatar bitmap missing")
    }
    require(bitmap.width <= 512 && bitmap.height <= 512, "Avatar was not downscaled")
    require(cache.image(for: "not base64") == nil, "Invalid avatar text decoded")
    require(cache.image(for: String(repeating: "a", count: 1_048_577)) == nil, "Oversized avatar was decoded")
    mark("monitors")
    for _ in 0..<5 {
      var monitored: Store? = Store(
        engine: try EngineProcess(
          executableURL: python,
          arguments: [fixture, "slow", "-"]))
      let weakMonitored = WeakReference(monitored)
      try await Task.sleep(nanoseconds: 100_000_000)
      monitored = nil
      try await waitReleased(weakMonitored, "Timer/event monitor retained the Store")
    }
    mark("appearance")
    for _ in 0..<100 {
      var appearance: SystemAppearance? = SystemAppearance()
      let weakAppearance = WeakReference(appearance)
      appearance = nil
      require(weakAppearance.value == nil, "Appearance observer retained its owner")
    }
    // Let the bounded child watchdogs finish before the test process exits.
    try await Task.sleep(nanoseconds: 2_100_000_000)
    print(
      "Native stability OK: read/write timeouts, EOF, malformed/oversized frames, cancellation, 10k note edits, 10k coalesced presence signals, busy ordering, Store deallocation, bounded avatar reuse, bounded browser queries, fresh focus reports, scoped note edits, import draft invalidation"
    )
  }
}
