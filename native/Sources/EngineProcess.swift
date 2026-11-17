import AppKit
import Darwin
import Foundation

/// A single ordered IPC channel. Pipe waits are bounded and cancellable, including writes.
final class EngineProcess: @unchecked Sendable {
  private let queue = DispatchQueue(label: "dev.ascend.engine", autoreleaseFrequency: .workItem)
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let lock = NSLock()
  private var stopped = false
  private var buffer = Data()
  private let timeout: TimeInterval
  private let maxResponseBytes: Int

  init(
    executableURL: URL? = nil, arguments: [String]? = nil,
    timeout: TimeInterval = 30, maxResponseBytes: Int = 128 * 1024 * 1024
  ) throws {
    self.timeout = timeout
    self.maxResponseBytes = maxResponseBytes
    process.executableURL =
      executableURL
      ?? Bundle.main.executableURL?.deletingLastPathComponent()
      .appendingPathComponent("ascend-engine")
    if let arguments {
      process.arguments = arguments
    } else {
      let args = CommandLine.arguments
      if let i = args.firstIndex(of: "--data-dir"), args.indices.contains(i + 1) {
        process.arguments = ["--data-dir", args[i + 1]]
      } else if args.contains("--demo") {
        process.arguments = ["--data-dir", NSTemporaryDirectory() + "ASCEND-demo"]
      }
    }
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    try process.run()
    for fd in [
      input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor,
    ] {
      let flags = fcntl(fd, F_GETFL)
      guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
        shutdown()
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
    }
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
  }
  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }
  private func unavailable() -> NSError {
    NSError(
      domain: "ASCEND", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Движок недоступен. Перезапустите ASCEND."])
  }
  private func wait(_ fd: Int32, for events: Int16, until deadline: TimeInterval) throws {
    while true {
      guard !isStopped else { throw unavailable() }
      let remaining = deadline - ProcessInfo.processInfo.systemUptime
      guard remaining > 0 else {
        throw NSError(
          domain: "ASCEND", code: 3,
          userInfo: [NSLocalizedDescriptionKey: "Движок не ответил вовремя. Перезапустите ASCEND."])
      }
      var descriptor = pollfd(fd: fd, events: events, revents: 0)
      let result = poll(&descriptor, 1, Int32(min(100, max(1, remaining * 1000))))
      if result > 0 { return }  // read/write reports EOF, EPIPE, and invalid descriptors below.
      if result < 0 && errno != EINTR {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
    }
  }
  private func exchange(_ command: [String: Any]) throws -> Response {
    guard process.isRunning, !isStopped else { throw unavailable() }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var data = try JSONSerialization.data(withJSONObject: command)
    data.append(10)
    let writeFD = input.fileHandleForWriting.fileDescriptor
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        try wait(writeFD, for: Int16(POLLOUT), until: deadline)
        let count = Darwin.write(
          writeFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count > 0 {
          offset += count
        } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
          continue
        } else {
          throw unavailable()
        }
      }
    }
    let readFD = output.fileHandleForReading.fileDescriptor
    var searchStart = buffer.startIndex
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      if let end = buffer[searchStart...].firstIndex(of: 10) {
        guard end - buffer.startIndex <= maxResponseBytes else { throw oversized() }
        let line = Data(buffer[..<end])
        buffer = Data(buffer[buffer.index(after: end)...])
        return try JSONDecoder().decode(Response.self, from: line)
      }
      guard buffer.count <= maxResponseBytes else { throw oversized() }
      searchStart = buffer.endIndex
      try wait(readFD, for: Int16(POLLIN), until: deadline)
      let count = Darwin.read(readFD, &chunk, chunk.count)
      if count > 0 {
        buffer.append(contentsOf: chunk.prefix(count))
      } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
        continue
      } else {
        throw unavailable()
      }
    }
  }
  private func oversized() -> NSError {
    NSError(
      domain: "ASCEND", code: 4,
      userInfo: [NSLocalizedDescriptionKey: "Ответ движка слишком большой. Перезапустите ASCEND."])
  }
  func send(_ command: [String: Any], completion: @escaping (Result<Response, Error>) -> Void) {
    queue.async { [self] in
      guard JSONSerialization.isValidJSONObject(command) else {
        let error = NSError(
          domain: "ASCEND", code: 5,
          userInfo: [NSLocalizedDescriptionKey: "Проверьте значения формы"])
        DispatchQueue.main.async { completion(.failure(error)) }
        return
      }
      let result = autoreleasepool { Result { try exchange(command) } }
      if case .failure = result { shutdown() }
      DispatchQueue.main.async { completion(result) }
    }
  }
  func shutdown() {
    lock.lock()
    guard !stopped else {
      lock.unlock()
      return
    }
    stopped = true
    lock.unlock()
    // Never close an FD underneath poll/read/write: finish the current exchange first.
    queue.async { [self] in
      buffer = Data()
      try? input.fileHandleForWriting.close()
      try? output.fileHandleForReading.close()
      let child = process
      DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
        if child.isRunning { child.terminate() }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
        if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
      }
    }
  }
  deinit {
    try? input.fileHandleForWriting.close()
    try? output.fileHandleForReading.close()
    if process.isRunning { process.terminate() }
  }
}
