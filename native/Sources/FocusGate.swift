import AppKit
import Foundation
import Darwin
import UniformTypeIdentifiers

enum FocusList {
  static let limit = 24
  static func site(_ raw: String) -> String? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !text.isEmpty, text.count <= 300 else { return nil }
    for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
      text.removeFirst(prefix.count)
    }
    if let index = text.firstIndex(where: { "/?#".contains($0) }) {
      text = String(text[..<index])
    }
    if let at = text.lastIndex(of: "@") {
      text = String(text[text.index(after: at)...])
    }
    if text.hasPrefix("www.") { text.removeFirst(4) }
    if let colon = text.firstIndex(of: ":") {
      let port = text[text.index(after: colon)...]
      guard !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
      text = String(text[..<colon])
    }
    while text.hasPrefix(".") { text.removeFirst() }
    while text.hasSuffix(".") { text.removeLast() }
    guard !text.isEmpty, text.count <= 253, text == "localhost" || text.contains(".") else {
      return nil
    }
    for label in text.split(separator: ".", omittingEmptySubsequences: false) {
      guard !label.isEmpty, label.count <= 63, !label.hasPrefix("-"), !label.hasSuffix("-") else {
        return nil
      }
      guard label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
        return nil
      }
    }
    return text
  }
  static func applicationName(_ bundle: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
      return bundle
    }
    return FileManager.default.displayName(atPath: url.path)
  }
  static func summary(_ skill: Skill) -> String {
    (skill.focusApps.map { applicationName($0) } + skill.focusSites).joined(separator: ", ")
  }
  static func chooseApplication() -> (bundle: String, name: String)? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.prompt = L("Add")
    guard panel.runModal() == .OK, let url = panel.url,
      let bundle = Bundle(url: url)?.bundleIdentifier, !bundle.isEmpty
    else { return nil }
    return (bundle, FileManager.default.displayName(atPath: url.path))
  }
}

enum FocusBrowser {
  private static let applications: [String: (name: String, safari: Bool)] = [
    "com.apple.Safari": ("Safari", true),
    "com.google.Chrome": ("Google Chrome", false),
    "com.google.Chrome.canary": ("Google Chrome Canary", false),
    "com.brave.Browser": ("Brave Browser", false),
    "com.microsoft.edgemac": ("Microsoft Edge", false),
    "com.microsoft.Edge": ("Microsoft Edge", false),
    "company.thebrowser.Browser": ("Arc", false),
    "com.operasoftware.Opera": ("Opera", false),
    "com.vivaldi.Vivaldi": ("Vivaldi", false),
    "org.chromium.Chromium": ("Chromium", false),
  ]
  static func knows(_ bundle: String) -> Bool { applications[bundle] != nil }
  static func read(_ bundle: String, completion: @escaping (String?) -> Void) {
    guard let application = applications[bundle] else {
      completion(nil)
      return
    }
    let property =
      application.safari
      ? "URL of current tab of front window" : "URL of active tab of front window"
    let source = "tell application \"\(application.name)\" to get \(property)"
    readOutput(executable: URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", source], completion: completion)
  }
  /// Both output and execution time are bounded, including children that ignore SIGTERM.
  static func readOutput(
    executable: URL, arguments: [String], timeout: TimeInterval = 8,
    completion: @escaping (String?) -> Void
  ) {
    DispatchQueue.global(qos: .utility).async {
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      let output = Pipe()
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      var host: String?
      defer {
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        DispatchQueue.main.async { completion(host) }
      }
      do { try process.run() } catch { return }
      let fd = output.fileHandleForReading.fileDescriptor
      let flags = fcntl(fd, F_GETFL)
      guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return }
      let deadline = ProcessInfo.processInfo.systemUptime + timeout
      var data = Data()
      var chunk = [UInt8](repeating: 0, count: 4096)
      var eof = false
      while ProcessInfo.processInfo.systemUptime < deadline {
        if !eof {
          var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
          let ready = poll(&descriptor, 1, 50)
          if ready < 0 && errno != EINTR { return }
          if ready > 0 {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
              guard data.count + count <= 64 * 1024 else { return }
              data.append(contentsOf: chunk.prefix(count))
            } else if count == 0 {
              eof = true
            } else if errno != EAGAIN && errno != EINTR { return }
          }
        }
        if eof {
          if !process.isRunning {
            if process.terminationStatus == 0 {
              let url = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
              host = URLComponents(string: url)?.host.flatMap(FocusList.site)
            }
            return
          }
          // A child can close stdout and keep running. Do not waitUntilExit indefinitely.
          Thread.sleep(forTimeInterval: 0.01)
        }
      }
    }
  }
}

@MainActor final class FocusReporter {
  var onReport: ((String, String?) -> Void)?
  var onActivate: (() -> Void)?
  private var observer: NSObjectProtocol?
  private var bundle = ""
  private var host: String?
  private var hostObservedAt: TimeInterval?
  private let now: () -> TimeInterval
  private let currentBundle: () -> String
  private let readHost: (String, @escaping (String?) -> Void) -> Void
  private var reading = false
  private var generation = 0
  init(
    currentBundle: @escaping () -> String = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "" },
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    readHost: @escaping (String, @escaping (String?) -> Void) -> Void = FocusBrowser.read
  ) {
    self.now = now
    self.currentBundle = currentBundle
    self.readHost = readHost
  }
  func start() {
    guard observer == nil else { return }
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.onActivate?() }
    }
  }
  func stop() {
    generation += 1
    reading = false
    host = nil
    hostObservedAt = nil
    if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    observer = nil
  }
  func sample(readSite: Bool) {
    let current = currentBundle()
    let now = self.now()
    if current != bundle {
      bundle = current
      host = nil
      hostObservedAt = nil
    }
    if hostObservedAt.map({ now - $0 >= 2 }) ?? true { host = nil }
    onReport?(current, host)
    guard readSite, FocusBrowser.knows(current), !reading else { return }
    reading = true
    generation += 1
    let token = generation
    readHost(current) { [weak self] found in
      guard let self, self.generation == token else { return }
      self.reading = false
      guard self.bundle == current, self.currentBundle() == current else { return }
      // A failed/slow browser query must revoke a previously allowed site.
      let fresh = self.now() - now < 2
      self.host = fresh ? found : nil
      self.hostObservedAt = fresh && found != nil ? now : nil
      self.onReport?(current, self.host)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
      guard let self, self.generation == token else { return }
      self.reading = false
      self.generation += 1
      self.host = nil
      self.hostObservedAt = nil
    }
  }
  deinit {
    if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
  }
}
