import AVFoundation
import Foundation
import ImageIO
import Vision

struct CameraPresenceFrame: Sendable {
  let observation: PresenceObservation
  let capturedAt: TimeInterval
  let wallTimeMS: UInt64
}
enum CameraPresenceEvent: Sendable {
  case started
  case frame(CameraPresenceFrame)
  case failed(String)
}

/// Capture setup and Vision inference never run on the UI thread.
final class CameraPresenceCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  let session = AVCaptureSession()
  private static let sessionQueue = DispatchQueue(label: "dev.ascend.camera.session", qos: .userInitiated)
  private let frameQueue = DispatchQueue(label: "dev.ascend.camera.vision", qos: .utility, autoreleaseFrequency: .workItem)
  private let output = AVCaptureVideoDataOutput()
  private let callback: @Sendable (CameraPresenceEvent) -> Void
  private var observers: [NSObjectProtocol] = []
  private let lifecycleLock = NSLock()
  private var cancelled = false
  private let deliveryLock = NSLock()
  private var pendingFrame: CameraPresenceFrame?
  private var deliveryScheduled = false
  private var lastAnalysis: TimeInterval = 0
  private let detector = FacePresenceDetector()
  init(callback: @escaping @Sendable (CameraPresenceEvent) -> Void) { self.callback = callback }
  func start() {
    Self.sessionQueue.async { [self] in
      guard !isCancelled else { return }
      do {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
          callback(.failed("Camera access is not allowed.")); return
        }
        guard let device = AVCaptureDevice.default(for: .video) else {
          callback(.failed("No camera is available.")); return
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        guard session.canAddInput(input), session.canAddOutput(output) else {
          session.commitConfiguration(); callback(.failed("Unable to configure the camera.")); return
        }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: frameQueue)
        session.addOutput(output)
        session.commitConfiguration()
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
          observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
            self?.callback(.failed("The camera was interrupted. Pause and resume, or end the session."))
          })
        }
        guard !isCancelled else { return }
        session.startRunning()
        callback(session.isRunning ? .started : .failed("The camera could not start."))
      } catch { callback(.failed("Unable to configure the camera.")) }
    }
  }
  private var isCancelled: Bool { lifecycleLock.withLock { cancelled } }
  func stop() {
    lifecycleLock.withLock { cancelled = true }
    deliveryLock.withLock { pendingFrame = nil }
    Self.sessionQueue.async { [self] in
      for observer in observers { NotificationCenter.default.removeObserver(observer) }
      observers.removeAll()
      output.setSampleBufferDelegate(nil, queue: nil)
      if session.isRunning { session.stopRunning() }
      session.beginConfiguration()
      for input in session.inputs { session.removeInput(input) }
      for item in session.outputs { session.removeOutput(item) }
      session.commitConfiguration()
    }
  }
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    let time = ProcessInfo.processInfo.systemUptime
    guard !isCancelled, time - lastAnalysis >= 0.45, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    lastAnalysis = time
    let wall = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
    let result: Result<PresenceObservation, Error> = autoreleasepool {
      Result { try detector.detect(in: VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)) }
    }
    switch result {
    case .success(let observation):
      deliver(CameraPresenceFrame(observation: observation, capturedAt: time, wallTimeMS: wall))
    case .failure:
      callback(.failed("Face detection failed. Restart the camera or end the session."))
    }
  }

  // A stalled UI retains at most one geometry observation, never a frame backlog.
  private func deliver(_ frame: CameraPresenceFrame) {
    let schedule = deliveryLock.withLock {
      pendingFrame = frame
      guard !deliveryScheduled else { return false }
      deliveryScheduled = true
      return true
    }
    guard schedule else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let latest = self.deliveryLock.withLock {
        let latest = self.pendingFrame
        self.pendingFrame = nil
        self.deliveryScheduled = false
        return latest
      }
      if let latest, !self.isCancelled { self.callback(.frame(latest)) }
    }
  }
  deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}
