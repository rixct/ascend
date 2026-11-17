import CoreGraphics
import Foundation

/// Geometry only. Camera frames and face identity never enter the timing gate.
enum PresenceObservation: Equatable, Sendable {
  case noFace
  case multipleFaces
  case face(CGRect)
}

enum PresenceStatus: Equatable {
  case noFace, multipleFaces, tooSmall, tooLarge, outsideFrame, outsideWorkArea, warmingUp, stale, confirmed
  var messageKey: String {
    switch self {
    case .noFace: "Face not found. Look toward the camera."
    case .multipleFaces: "Only one person should be in the frame."
    case .tooSmall: "Move closer to the camera."
    case .tooLarge: "Move a little farther from the camera."
    case .outsideFrame: "Keep your face inside the frame."
    case .outsideWorkArea: "Return to your starting position."
    case .warmingUp: "Hold your position for a moment."
    case .stale: "Waiting for a fresh camera frame."
    case .confirmed: "Presence confirmed"
    }
  }
}

struct PresenceGate {
  static let freshness: TimeInterval = 1
  private(set) var present = false
  private(set) var latest: CGRect?
  private(set) var latestTime: TimeInterval?
  private(set) var status: PresenceStatus = .noFace
  private var positives = 0
  private var reference: CGRect?
  var calibrated: Bool { reference != nil }

  mutating func sample(_ observation: PresenceObservation, capturedAt: TimeInterval, now: TimeInterval) -> Bool {
    guard capturedAt.isFinite, now.isFinite, capturedAt <= now + 0.1, now - capturedAt <= Self.freshness,
      latestTime.map({ capturedAt > $0 }) ?? true
    else { return reject(.stale) }
    if let previous = latestTime, capturedAt - previous >= Self.freshness { positives = 0 }
    latestTime = capturedAt
    latest = nil
    switch observation {
    case .noFace: return reject(.noFace)
    case .multipleFaces: return reject(.multipleFaces)
    case .face(let face):
      guard [face.origin.x, face.origin.y, face.width, face.height].allSatisfy(\.isFinite),
        face.minX >= -0.02, face.maxX <= 1.02, face.minY >= -0.02, face.maxY <= 1.02
      else { return reject(.outsideFrame) }
      guard face.width >= 0.035, face.height >= 0.045 else { return reject(.tooSmall) }
      guard face.width <= 0.95, face.height <= 0.98 else { return reject(.tooLarge) }
      guard matchesReference(face) else { return reject(.outsideWorkArea) }
      latest = face
      positives = min(2, positives + 1)
      present = positives >= 2
      status = present ? .confirmed : .warmingUp
      return present
    }
  }
  private mutating func reject(_ reason: PresenceStatus) -> Bool {
    positives = 0
    present = false
    status = reason
    return false
  }
  private func matchesReference(_ face: CGRect) -> Bool {
    guard let reference else { return true }
    // Allow natural head movement and leaning toward a laptop camera.
    return abs(face.midX - reference.midX) <= 0.32 && abs(face.midY - reference.midY) <= 0.28
      && face.width >= reference.width * 0.35 && face.width <= reference.width * 3
  }
  mutating func lockPosition() { if present { reference = latest } }
  mutating func expire(now: TimeInterval) -> Bool {
    if latestTime.map({ now - $0 >= Self.freshness }) ?? true { return reject(.stale) }
    return present
  }
  mutating func reset(keepPosition: Bool = false) {
    let position = keepPosition ? reference : nil
    self = PresenceGate()
    reference = position
  }
}
