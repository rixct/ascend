import AppKit
import AVFoundation
import SwiftUI

@MainActor final class PresenceMonitor: ObservableObject {
  @Published private(set) var previewSession: AVCaptureSession?
  @Published private(set) var cameraRunning = false
  @Published private(set) var detected = false
  @Published private(set) var requesting = false
  @Published private(set) var statusKey = "Camera is off"
  @Published private(set) var failureKey: String?
  var onPresence: ((String, Bool, UInt64) -> Void)?
  private var capture: CameraPresenceCapture?
  private var generation = UUID()
  private var gate = PresenceGate()
  private var watchdog: Timer?
  private var preparing = false
  private var awaitingStart = false
  private var activeID: String?
  private var wantsRunning = false
  private var lastSent: Bool?
  private var activeKey = ""
  private var startedAt: TimeInterval?
  private var permissionToken = UUID()
  private var permissionTask: Task<Void, Never>?

  var ready: Bool {
    cameraRunning && detected && gate.latestTime.map { ProcessInfo.processInfo.systemUptime - $0 < PresenceGate.freshness } == true
  }
  func beginPreparation() {
    end()
    preparing = true
    statusKey = "Enable the camera before starting."
  }
  func enableForPreparation() {
    guard preparing, !requesting, capture == nil else { return }
    requesting = true
    let token = UUID()
    permissionToken = token
    permissionTask = Task { [weak self] in
      guard !Task.isCancelled else { return }
      var status = AVCaptureDevice.authorizationStatus(for: .video)
      if status == .notDetermined {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        status = AVCaptureDevice.authorizationStatus(for: .video)
      }
      guard let self, self.permissionToken == token else { return }
      defer { self.requesting = false; self.permissionTask = nil }
      guard !Task.isCancelled, self.preparing else { return }
      guard status == .authorized else {
        self.failureKey = "Allow camera access in macOS Settings, or start without the camera."
        self.statusKey = "Camera access is not allowed."
        return
      }
      self.startCapture()
    }
  }
  func stopPreparationCamera() {
    guard preparing else { return }
    permissionToken = UUID()
    permissionTask?.cancel()
    permissionTask = nil
    requesting = false
    stopCapture(keepPosition: false)
    failureKey = nil
    statusKey = "Camera is off"
  }
  func commitPreparation() -> Bool {
    guard preparing, ready else { return false }
    gate.lockPosition()
    preparing = false
    awaitingStart = true
    return true
  }
  func cancelPreparation() { if preparing { end() } }
  func sync(active: ActiveSession?) {
    let key = active.map { "\($0.id):\($0.isStrict):\($0.running)" } ?? ""
    guard key != activeKey else { return }
    activeKey = key
    guard let active, active.isStrict else {
      if !preparing && !awaitingStart { end(); activeKey = key }
      return
    }
    if activeID != active.id {
      if !awaitingStart { stopCapture(keepPosition: false) }
      activeID = active.id
      lastSent = nil
    }
    preparing = false
    awaitingStart = false
    wantsRunning = active.running
    if active.running {
      if capture == nil {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
          failureKey = "Camera permission is unavailable. End this session and choose a mode again."
          self.statusKey = "Camera access is not allowed."
          publish(false)
          return
        }
        startCapture()
      }
    } else {
      publish(false)
      stopCapture(keepPosition: true)
      statusKey = "Session paused"
    }
  }
  private func startCapture() {
    guard capture == nil else { return }
    failureKey = nil
    statusKey = "Starting camera…"
    generation = UUID()
    let token = generation
    let source = CameraPresenceCapture { [weak self] event in
      Task { @MainActor [weak self] in self?.receive(event, token: token) }
    }
    capture = source
    previewSession = source.session
    startedAt = ProcessInfo.processInfo.systemUptime
    startWatchdog()
    source.start()
  }
  private func receive(_ event: CameraPresenceEvent, token: UUID) {
    guard token == generation, capture != nil else { return }
    switch event {
    case .started:
      cameraRunning = true
      statusKey = "Sit in front of the camera."
    case .failed(let key):
      publish(false)
      failureKey = key
      stopCapture(keepPosition: true)
      statusKey = key
    case .frame(let frame):
      guard cameraRunning else { return }
      let present = gate.sample(frame.observation, capturedAt: frame.capturedAt, now: ProcessInfo.processInfo.systemUptime)
      if present, activeID != nil, !gate.calibrated { gate.lockPosition() }
      setDetected(present)
      publish(present, at: frame.wallTimeMS)
    }
  }
  private func setDetected(_ value: Bool) {
    if detected != value { detected = value }
    let key = value ? "Presence confirmed" : gate.status.messageKey
    if statusKey != key { statusKey = key }
  }
  private func publish(_ value: Bool, at time: UInt64? = nil) {
    guard let activeID, wantsRunning, value || lastSent != false else { return }
    lastSent = value
    onPresence?(activeID, value, time ?? UInt64(max(0, Date().timeIntervalSince1970 * 1000)))
  }
  private func startWatchdog() {
    watchdog?.invalidate()
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.checkFreshness() }
    }
    RunLoop.main.add(timer, forMode: .common)
    watchdog = timer
  }
  private func checkFreshness() {
    guard capture != nil else { return }
    if cameraRunning, !gate.expire(now: ProcessInfo.processInfo.systemUptime) {
      setDetected(false)
      publish(false)
    }
    if let reference = gate.latestTime ?? startedAt, ProcessInfo.processInfo.systemUptime - reference > 6 {
      publish(false)
      failureKey = "The camera is not sending frames. Pause and resume, or end the session."
      stopCapture(keepPosition: true)
      statusKey = failureKey ?? "Camera is off"
    }
  }
  private func stopCapture(keepPosition: Bool) {
    generation = UUID()
    capture?.stop()
    capture = nil
    previewSession = nil
    cameraRunning = false
    detected = false
    gate.reset(keepPosition: keepPosition)
    watchdog?.invalidate()
    watchdog = nil
    startedAt = nil
  }
  func end() {
    publish(false)
    preparing = false
    awaitingStart = false
    activeID = nil
    activeKey = ""
    wantsRunning = false
    lastSent = nil
    permissionToken = UUID()
    permissionTask?.cancel()
    permissionTask = nil
    requesting = false
    stopCapture(keepPosition: false)
    failureKey = nil
    statusKey = "Camera is off"
  }
  func openSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") { NSWorkspace.shared.open(url) }
  }
  deinit { watchdog?.invalidate(); permissionTask?.cancel(); capture?.stop() }
}
