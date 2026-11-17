import AppKit
import Foundation

extension Notification.Name { static let ascendSave = Notification.Name("dev.ascend.save") }

private final class WeakReference<T: AnyObject> {
  weak var value: T?
  init(_ value: T?) { self.value = value }
}

@main struct StabilityTests {
  @MainActor static func request(_ engine: EngineProcess, _ payload: [String: Any]) async -> Result<
    Response, Error
  > {
    await withCheckedContinuation { continuation in
      engine.send(payload) { continuation.resume(returning: $0) }
    }
  }
  @MainActor static func main() async throws {
    let args = CommandLine.arguments
    let python = URL(fileURLWithPath: args[1])
    let fixture = args[2]
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
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
      guard case .failure = result else { fatalError("Expected bounded failure for \(mode)") }
      precondition(
        ProcessInfo.processInfo.systemUptime - started < 2, "Unbounded pipe wait: \(mode)")
      engine.shutdown()
    }
    let healthy = try EngineProcess(executableURL: python, arguments: [fixture, "slow", "-"])
    guard case .failure = await request(healthy, ["command": "settings", "value": Double.nan])
    else {
      fatalError("Non-finite values must fail before writing to the pipe")
    }
    guard case .success = await request(healthy, ["command": "load"]) else {
      fatalError("Invalid form values must not shut down a healthy engine")
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
    guard case .failure = await cancellation.value else {
      fatalError("Cancellation did not reach pending read")
    }
    try await Task.sleep(nanoseconds: 150_000_000)
    precondition(releasedTransport.value == nil, "IPC transport retained after cancellation")

    var deferredStore: Store? = Store(startMonitoring: false)
    let releasedDeferredStore = WeakReference(deferredStore)
    deferredStore = nil
    try await Task.sleep(nanoseconds: 100_000_000)
    precondition(releasedDeferredStore.value == nil, "Deferred startup retained an unused Store")

    let log = directory.appendingPathComponent("commands.jsonl")
    var store: Store? = Store(
      engine: try EngineProcess(executableURL: python, arguments: [fixture, "slow", log.path]),
      startMonitoring: false)
    let releasedStore = WeakReference(store)
    for index in 0..<10_000 { store?.send("notes", ["text": "note \(index)"]) }
    var finalAction = false
    store?.send("backup") { finalAction = true }
    precondition(store?.busy == true)
    for _ in 0..<100 {
      if finalAction { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    precondition(finalAction && store?.busy == false, "Queue did not finish in order")
    let commands = try String(contentsOf: log).split(separator: "\n").map {
      try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }
    precondition(commands.count == 3, "Keystrokes created an unbounded IPC backlog")
    precondition(commands[1]["text"] as? String == "note 9999")
    precondition(commands[2]["command"] as? String == "backup")
    store?.cancelImport()
    var importConfirmed = false
    store?.send("confirm_import") { importConfirmed = true }
    for _ in 0..<100 {
      if importConfirmed { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let importLog = try String(contentsOf: log)
    precondition(
      !importLog.contains("cancel_import"), "Dismissal cancelled Replace before its action")
    store?.cancelImport()
    try await Task.sleep(nanoseconds: 100_000_000)
    let cancelledLog = try String(contentsOf: log)
    precondition(cancelledLog.contains("cancel_import"))
    store?.skillSelection = ["one", "two", "three"]
    store?.deleteSelectedSkills()
    for _ in 0..<100 {
      if store?.skillSelection.isEmpty == true { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    precondition(store?.skillSelection.isEmpty == true)
    store = nil
    try await Task.sleep(nanoseconds: 200_000_000)
    precondition(releasedStore.value == nil, "Store retained after recursive skill deletion")

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
    for _ in 0..<100 {
      if presenceFinished { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    precondition(presenceFinished)
    let presenceCommands = try String(contentsOf: presenceLog).split(separator: "\n").map {
      try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }
    precondition(presenceCommands.count == 3, "Presence created an unbounded IPC backlog")
    precondition(presenceCommands[1]["present"] as? Bool == false, "A queued positive replaced the latest absence")
    precondition(presenceCommands[1]["observed_at_ms"] as? Int == 9999)
    presenceStore = nil
    try await Task.sleep(nanoseconds: 100_000_000)
    precondition(releasedPresenceStore.value == nil, "Presence callback retained the Store")

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
    precondition(saved.contains("exit note 9999"), "Termination lost the coalesced draft")
    exitStore = nil
    try await Task.sleep(nanoseconds: 100_000_000)
    precondition(releasedExitStore.value == nil)

    // Browser automation must not strand utility threads or accumulate blocked pipes.
    for mode in ["focus_ok", "focus_long_url", "focus_failed", "focus_flood", "focus_stubborn"] {
      let started = ProcessInfo.processInfo.systemUptime
      let host: String? = await withCheckedContinuation { continuation in
        FocusBrowser.readOutput(executable: python, arguments: [fixture, mode, "-"], timeout: 0.3) {
          continuation.resume(returning: $0)
        }
      }
      precondition(host == (["focus_ok", "focus_long_url"].contains(mode) ? "example.com" : nil))
      precondition(ProcessInfo.processInfo.systemUptime - started < 1.5, "Browser query hung: \(mode)")
    }
    var browser = "com.apple.Safari"
    var uptime: TimeInterval = 100
    var browserReply: ((String?) -> Void)?
    var reportedHost: String?
    let reporter = FocusReporter(currentBundle: { browser }, now: { uptime }, readHost: { _, reply in browserReply = reply })
    reporter.onReport = { _, host in reportedHost = host }
    reporter.sample(readSite: true)
    browserReply?("example.com")
    precondition(reportedHost == "example.com")
    reporter.sample(readSite: true)
    browserReply?(nil)
    precondition(reportedHost == nil, "A failed browser query retained the allowed site")
    reporter.sample(readSite: true)
    browserReply?("example.com")
    uptime += 2.1
    reporter.sample(readSite: true)
    precondition(reportedHost == nil, "Expired browser observations kept authorizing focus")
    uptime += 2.1
    browserReply?("example.com")
    precondition(reportedHost == nil, "A delayed browser response authorized stale focus")
    reporter.sample(readSite: true)
    browser = "com.apple.TextEdit"
    browserReply?("example.com")
    precondition(reportedHost == nil, "A browser response outlived the frontmost application")
    reporter.stop()

    let scopedLog = directory.appendingPathComponent("scoped-notes.jsonl")
    let scopedStore = Store(engine: try EngineProcess(executableURL: python, arguments: [fixture, "slow", scopedLog.path]), startMonitoring: false)
    scopedStore.send("notes", ["id": "first", "text": "first draft"])
    scopedStore.send("notes", ["id": "second", "text": "second draft"])
    var scopedFinished = false
    scopedStore.send("backup") { scopedFinished = true }
    for _ in 0..<100 {
      if scopedFinished { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let scopedCommands = try String(contentsOf: scopedLog)
    precondition(scopedCommands.contains("first draft") && scopedCommands.contains("second draft"), "Note coalescing crossed session boundaries")
    var importFinished = false
    scopedStore.send("confirm_import") { importFinished = true }
    for _ in 0..<100 {
      if importFinished { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    precondition(importFinished && scopedStore.profileGeneration == 1, "Import did not invalidate profile drafts")
    scopedStore.shutdown()

    let png = try Data(contentsOf: URL(fileURLWithPath: args[3])).base64EncodedString()
    let cache = AvatarImages()
    let image = cache.image(for: png)!
    for _ in 0..<10_000 {
      autoreleasepool { precondition(cache.image(for: png) === image) }
    }
    let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    precondition(bitmap.width <= 512 && bitmap.height <= 512)
    precondition(cache.image(for: "not base64") == nil)
    precondition(cache.image(for: String(repeating: "a", count: 1_048_577)) == nil)
    for _ in 0..<5 {
      var monitored: Store? = Store(
        engine: try EngineProcess(
          executableURL: python,
          arguments: [fixture, "slow", "-"]))
      let weakMonitored = WeakReference(monitored)
      try await Task.sleep(nanoseconds: 100_000_000)
      monitored = nil
      try await Task.sleep(nanoseconds: 100_000_000)
      precondition(weakMonitored.value == nil, "Timer/event monitor retained the Store")
    }
    for _ in 0..<100 {
      var appearance: SystemAppearance? = SystemAppearance()
      let weakAppearance = WeakReference(appearance)
      appearance = nil
      precondition(weakAppearance.value == nil, "Appearance observer retained its owner")
    }
    // Let the bounded child watchdogs finish before the test process exits.
    try await Task.sleep(nanoseconds: 2_100_000_000)
    print(
      "Native stability OK: read/write timeouts, EOF, malformed/oversized frames, cancellation, 10k note edits, 10k coalesced presence signals, busy ordering, Store deallocation, bounded avatar reuse, bounded browser queries, fresh focus reports, scoped note edits, import draft invalidation"
    )
  }
}
