import AppKit

let directory = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let w = CGFloat(pixels)
        // macOS icon grid: 824pt body inside a 1024pt canvas, so the Dock tile matches other apps.
        let margin = w * 100 / 1024
        let side = w * 824 / 1024
        let bounds = NSRect(x: margin, y: margin, width: side, height: side)
        let radius = side * 185 / 824
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor(red: 0.11, green: 0.13, blue: 0.12, alpha: 1).setFill()
        shape.fill()

        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: margin + side * x, y: margin + side * y)
        }
        let mark = NSBezierPath()
        mark.move(to: pt(0.25, 0.348))
        mark.line(to: pt(0.50, 0.696))
        mark.line(to: pt(0.75, 0.348))
        mark.lineWidth = side * 0.096
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round
        NSColor(red: 0.95, green: 0.97, blue: 0.95, alpha: 1).setStroke()
        mark.stroke()

        NSGraphicsContext.restoreGraphicsState()
        let png = bitmap.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: URL(fileURLWithPath: "\(directory)/icon_\(size)x\(size)\(suffix).png"))
    }
}
