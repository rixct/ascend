import Vision

/// One request reused on the serial inference queue. Shoulder/body detection must
/// not veto a visible face in the close framing of a laptop webcam.
final class FacePresenceDetector {
  private let request = VNDetectFaceRectanglesRequest()
  func detect(in handler: VNImageRequestHandler) throws -> PresenceObservation {
    try handler.perform([request])
    let faces = (request.results ?? []).filter { $0.confidence >= 0.5 }
    guard faces.count < 2 else { return .multipleFaces }
    guard let face = faces.first else { return .noFace }
    return .face(face.boundingBox)
  }
}
