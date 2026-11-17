import AVFoundation
import Foundation
import ImageIO
import Vision

@main struct PresenceTests {
  static func pixelBuffer(_ image: CGImage) -> CVPixelBuffer {
    var result: CVPixelBuffer?
    let options = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
    precondition(CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA, options, &result) == kCVReturnSuccess)
    let buffer = result!
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return buffer
  }
  static func canvas(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    draw(context)
    return context.makeImage()!
  }
  static func visionRegression() throws {
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil)!
    let portrait = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let detector = FacePresenceDetector()
    guard case .face(let face) = try detector.detect(in: VNImageRequestHandler(cgImage: portrait)) else {
      fatalError("Vision did not detect the public test portrait")
    }
    let box = CGRect(x: face.minX * CGFloat(portrait.width), y: (1-face.maxY) * CGFloat(portrait.height), width: face.width * CGFloat(portrait.width), height: face.height * CGFloat(portrait.height))
    let closeup = portrait.cropping(to: box.insetBy(dx: -box.width * 0.3, dy: -box.height * 0.3))!
    for (name, image) in [("portrait", portrait), ("face without shoulders", closeup)] {
      // Exercise the BGRA pixel-buffer path used by the actual camera delegate.
      let observation = try detector.detect(in: VNImageRequestHandler(cvPixelBuffer: pixelBuffer(image), orientation: .up))
      guard case .face = observation else { fatalError("Vision failed on \(name)") }
      var gate = PresenceGate()
      precondition(!gate.sample(observation, capturedAt: 100, now: 100))
      precondition(gate.sample(observation, capturedAt: 100.5, now: 100.5), "Visible \(name) must unlock Start without shoulder detection")
      gate.lockPosition()
      precondition(!gate.sample(.noFace, capturedAt: 101, now: 101), "An empty frame must still stop time immediately")
    }
    let blank = canvas(width: 640, height: 480) { _ in }
    let blankResult = try detector.detect(in: VNImageRequestHandler(cvPixelBuffer: pixelBuffer(blank)))
    precondition(blankResult == .noFace)
    let pair = canvas(width: portrait.width * 2, height: portrait.height) { context in
      context.draw(portrait, in: CGRect(x: 0, y: 0, width: portrait.width, height: portrait.height))
      context.draw(portrait, in: CGRect(x: portrait.width, y: 0, width: portrait.width, height: portrait.height))
    }
    let pairResult = try detector.detect(in: VNImageRequestHandler(cvPixelBuffer: pixelBuffer(pair)))
    precondition(pairResult == .multipleFaces)
    print("Vision regression OK: real portrait and close-up without shoulders unlock Start; blank BGRA frame and two faces are rejected")
  }
  @MainActor static func main() throws {
    let geometry = PresenceObservation.face(CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.2))
    var gate = PresenceGate()
    precondition(!gate.sample(geometry, capturedAt: 10, now: 10))
    precondition(gate.status == .warmingUp)
    precondition(gate.sample(geometry, capturedAt: 10.5, now: 10.5))
    gate.lockPosition()
    precondition(!gate.sample(.noFace, capturedAt: 11, now: 11))
    precondition(gate.status == .noFace)
    precondition(!gate.sample(geometry, capturedAt: 11.5, now: 11.5))
    precondition(gate.sample(geometry, capturedAt: 12, now: 12))
    precondition(!gate.expire(now: 13), "A frozen camera must stop detection")
    precondition(gate.status == .stale)
    precondition(!gate.sample(geometry, capturedAt: 12.5, now: 15), "Stale frames cannot revive presence")
    precondition(!gate.sample(geometry, capturedAt: 20, now: 15), "Future frames cannot revive presence")
    precondition(!gate.sample(geometry, capturedAt: 16, now: 16))
    precondition(!gate.sample(geometry, capturedAt: 16, now: 16), "Duplicate frame cannot establish presence")
    let movement = PresenceObservation.face(CGRect(x: 0.5, y: 0.35, width: 0.25, height: 0.25))
    precondition(!gate.sample(movement, capturedAt: 16.5, now: 16.5))
    precondition(gate.sample(movement, capturedAt: 17, now: 17), "Normal head movement must not look like an absent user")
    let outside = PresenceObservation.face(CGRect(x: 0.85, y: 0.6, width: 0.1, height: 0.1))
    precondition(!gate.sample(outside, capturedAt: 17.5, now: 17.5))
    precondition(gate.status == .outsideWorkArea)
    gate.reset(keepPosition: true)
    precondition(!gate.sample(outside, capturedAt: 18, now: 18))
    gate.reset()
    precondition(!gate.sample(outside, capturedAt: 19, now: 19))
    precondition(gate.sample(outside, capturedAt: 19.5, now: 19.5), "A face near the edge must be accepted before calibration")
    precondition(!gate.sample(.multipleFaces, capturedAt: 20, now: 20))
    precondition(gate.status == .multipleFaces)
    precondition(!gate.sample(.face(CGRect(x: 0.5, y: 0.5, width: 0.02, height: 0.02)), capturedAt: 20.5, now: 20.5))
    precondition(gate.status == .tooSmall)
    precondition(!gate.sample(.face(CGRect(x: 0, y: 0, width: 0.99, height: 0.99)), capturedAt: 21, now: 21))
    precondition(gate.status == .tooLarge)
    precondition(!gate.sample(.face(CGRect(x: -0.2, y: 0.5, width: 0.3, height: 0.3)), capturedAt: 21.5, now: 21.5))
    precondition(gate.status == .outsideFrame)
    precondition(!gate.sample(geometry, capturedAt: .nan, now: 22))
    precondition(gate.status == .stale)

    let legacy = try JSONDecoder().decode(ActiveSession.self, from: Data(#"{"id":"s","quest_id":"q","elapsed_seconds":0,"running":true,"notes":""}"#.utf8))
    precondition(!legacy.isStrict && legacy.isCounting)
    var strict = legacy
    strict.strict = true
    precondition(!strict.isCounting)
    strict.presence_confirmed = true
    precondition(strict.isCounting)
    strict.running = false
    precondition(!strict.isCounting)
    let authorization = AVCaptureDevice.authorizationStatus(for: .video)
    weak var released: PresenceMonitor?
    autoreleasepool {
      let monitor = PresenceMonitor()
      released = monitor
      for _ in 0..<1000 {
        monitor.beginPreparation()
        precondition(!monitor.ready && monitor.previewSession == nil)
        monitor.stopPreparationCamera()
        monitor.cancelPreparation()
        monitor.sync(active: legacy)
        monitor.sync(active: nil)
      }
      monitor.end()
    }
    precondition(released == nil, "Preparation must not retain its owner")
    try visionRegression()
    precondition(AVCaptureDevice.authorizationStatus(for: .video) == authorization)
    print("Presence OK: face-only warmup, absence, stale/duplicate/future frames, natural movement, reason statuses, model compatibility, 1000 preparation teardown cycles; camera never enabled")
  }
}
