import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate_app_icon.swift <iconset-directory>\n", stderr)
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let iconSizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

func drawIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "CodePulseIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create icon bitmap"])
    }

    let context = graphicsContext.cgContext
    let scale = CGFloat(size) / 1024
    context.saveGState()
    context.scaleBy(x: scale, y: scale)

    let backgroundRect = CGRect(x: 72, y: 72, width: 880, height: 880)
    let backgroundPath = CGPath(roundedRect: backgroundRect, cornerWidth: 224, cornerHeight: 224, transform: nil)
    context.saveGState()
    context.addPath(backgroundPath)
    context.clip()

    let backgroundGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0.08, 0.10, 0.20), color(0.15, 0.24, 0.45)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        backgroundGradient,
        start: CGPoint(x: 160, y: 940),
        end: CGPoint(x: 860, y: 100),
        options: []
    )
    context.restoreGState()

    context.setStrokeColor(color(0.88, 0.94, 1.0, 0.95))
    context.setLineWidth(54)
    context.setLineCap(CGLineCap.round)
    context.strokeEllipse(in: CGRect(x: 250, y: 270, width: 524, height: 524))

    context.setFillColor(color(0.88, 0.94, 1.0, 0.95))
    context.fill(CGRect(x: 474, y: 766, width: 76, height: 92))

    let pulse = CGMutablePath()
    pulse.move(to: CGPoint(x: 246, y: 532))
    pulse.addLine(to: CGPoint(x: 352, y: 532))
    pulse.addLine(to: CGPoint(x: 410, y: 414))
    pulse.addLine(to: CGPoint(x: 510, y: 656))
    pulse.addLine(to: CGPoint(x: 595, y: 474))
    pulse.addLine(to: CGPoint(x: 654, y: 532))
    pulse.addLine(to: CGPoint(x: 778, y: 532))
    context.addPath(pulse)
    context.setStrokeColor(color(0.33, 0.85, 0.92))
    context.setLineWidth(42)
    context.setLineCap(CGLineCap.round)
    context.setLineJoin(CGLineJoin.round)
    context.strokePath()
    context.restoreGState()

    guard let data = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
        throw NSError(domain: "CodePulseIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode icon bitmap"])
    }
    return data
}

for (size, filename) in iconSizes {
    let destination = outputDirectory.appendingPathComponent(filename)
    try drawIcon(size: size).write(to: destination, options: .atomic)
}
