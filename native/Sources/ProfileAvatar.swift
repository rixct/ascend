import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ProfileAvatar: View {
  let encodedImage: String?
  var size: CGFloat = 72
  var circular = false
  private var image: NSImage? {
    AvatarImages.shared.image(for: encodedImage)
  }
  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().scaledToFill()
      } else {
        Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
          .foregroundStyle(AppStyle.accent.gradient).padding(size * 0.16)
      }
    }
    .frame(width: size, height: size)
    .background(AppStyle.accent.opacity(0.075))
    .clipShape(avatarShape)
    .overlay { avatarShape.stroke(Color.primary.opacity(0.06), lineWidth: 1) }
    .accessibilityLabel("Profile photo")
  }
  private var avatarShape: AnyShape {
    circular
      ? AnyShape(Circle())
      : AnyShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
  }
}

enum AvatarPicker {
  static func choose(completion: @escaping (Result<String?, Error>) -> Void) {
    let panel = NSOpenPanel()
    panel.title = L("Choose a profile photo")
    panel.prompt = L("Choose")
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    let finish: (NSApplication.ModalResponse) -> Void = { [weak panel] response in
      guard response == .OK, let url = panel?.url else {
        completion(.success(nil))
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let result: Result<String?, Error> = autoreleasepool { Result { try read(url) } }
        DispatchQueue.main.async { completion(result) }
      }
    }
    if let window = NSApp.keyWindow {
      panel.beginSheetModal(for: window, completionHandler: finish)
    } else {
      panel.begin(completionHandler: finish)
    }
  }
  private static func read(_ url: URL) throws -> String {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 512,
        ] as CFDictionary),
      let context = CGContext(
        data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw AvatarError.invalidImage }
    let scale = max(256 / CGFloat(image.width), 256 / CGFloat(image.height))
    let width = CGFloat(image.width) * scale
    let height = CGFloat(image.height) * scale
    context.interpolationQuality = .high
    context.draw(
      image, in: CGRect(x: (256 - width) / 2, y: (256 - height) / 2, width: width, height: height))
    guard let cropped = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
    else { throw AvatarError.invalidImage }
    return png.base64EncodedString()
  }
  enum AvatarError: LocalizedError {
    case invalidImage
    var errorDescription: String? { L("This image could not be opened. Try a different photo.") }
  }
}

/// The same decoded bitmap serves the sidebar, character and settings views.
/// A pixel limit also bounds decoded memory for small compressed images from JSON imports.
final class AvatarImages {
  static let shared = AvatarImages()
  private final class Entry: NSObject {
    let image: NSImage?
    init(_ image: NSImage?) { self.image = image }
  }
  private let cache = NSCache<NSString, Entry>()
  init() {
    cache.countLimit = 8
    cache.totalCostLimit = 8 * 1024 * 1024
  }
  func image(for encoded: String?) -> NSImage? {
    guard let encoded, encoded.utf8.count <= 1_048_576 else { return nil }
    let key = encoded as NSString
    if let cached = cache.object(forKey: key) { return cached.image }
    var image: NSImage?
    var cost = encoded.utf8.count
    if let data = Data(base64Encoded: encoded),
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let bitmap = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 512,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    {
      image = NSImage(cgImage: bitmap, size: NSSize(width: bitmap.width, height: bitmap.height))
      cost += bitmap.bytesPerRow * bitmap.height
    }
    cache.setObject(Entry(image), forKey: key, cost: cost)
    return image
  }
}
