import AppKit
import Foundation

func fail(_ message: String) -> Never {
    fputs("DMG background render failed: \(message)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 5 else {
    fail("usage: render-dmg-background.swift <source.svg> <output.png> <width> <height>")
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let width = Int(CommandLine.arguments[3]), width > 0,
      let height = Int(CommandLine.arguments[4]), height > 0 else {
    fail("width and height must be positive integers")
}
guard let image = NSImage(contentsOf: sourceURL) else {
    fail("cannot load \(sourceURL.path)")
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fail("cannot allocate a \(width)x\(height) bitmap")
}

bitmap.size = NSSize(width: width, height: height)
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fail("cannot create a bitmap graphics context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
image.draw(
    in: NSRect(x: 0, y: 0, width: width, height: height),
    from: NSRect(origin: .zero, size: image.size),
    operation: .copy,
    fraction: 1
)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fail("cannot encode PNG data")
}

do {
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try pngData.write(to: outputURL, options: .atomic)
} catch {
    fail("cannot write \(outputURL.path): \(error.localizedDescription)")
}
