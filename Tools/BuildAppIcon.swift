import AppKit

// Package the approved artwork as native icon resources; do not modify the master.
// Usage: swift Tools/BuildAppIcon.swift MASTER.png OUTPUT.iconset
//        swift Tools/BuildAppIcon.swift --verify APP_PATH PREVIEW.png
guard CommandLine.arguments.count == 3 || CommandLine.arguments.count == 4 else {
    fatalError("Pass master PNG and output .iconset, or --verify app and preview PNG")
}
let verify = CommandLine.arguments[1] == "--verify"
let source: NSImage
if verify {
    source = NSWorkspace.shared.icon(forFile: CommandLine.arguments[2])
} else {
    guard let loaded = NSImage(contentsOfFile: CommandLine.arguments[1]) else { fatalError("Missing icon artwork") }
    source = loaded
}

func png(size: Int, mask: Bool) throws -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let side = CGFloat(size)
    let canvas = NSRect(x: 0, y: 0, width: side, height: side)
    NSColor.clear.setFill(); canvas.fill(using: .copy)
    let tile = mask ? canvas.insetBy(dx: side * 0.094, dy: side * 0.094) : canvas
    if mask {
        NSBezierPath(roundedRect: tile, xRadius: side * 0.18, yRadius: side * 0.18).addClip()
    }
    source.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1,
        respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if verify {
    let data = try png(size: 512, mask: false)
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
    let image = NSBitmapImageRep(data: data)!
    var redPixels = 0
    for y in 0..<image.pixelsHigh {
        for x in 0..<image.pixelsWide {
            guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if c.alphaComponent > 0.8 && c.redComponent > 0.5 && c.redComponent > c.greenComponent * 1.8 && c.redComponent > c.blueComponent * 1.8 { redPixels += 1 }
        }
    }
    guard redPixels > 20 else { fatalError("System icon did not resolve the new red-accent artwork") }
    print("System-resolved app icon verified; red accent pixels: \(redPixels)")
} else {
    let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let suffix = scale == 2 ? "@2x" : ""
            let name = "icon_\(points)x\(points)\(suffix).png"
            try png(size: points * scale, mask: true).write(to: directory.appendingPathComponent(name))
        }
    }
    print("Generated 10 native icon sizes")
}
