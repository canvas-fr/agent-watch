import AppKit

// Original Agent Watch artwork: a pulse inside an observation ring.
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources")
let iconset = output.appendingPathComponent("AgentWatch.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for scale in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let pixels = scale * factor
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 192, yRadius: 192)
        let gradient = NSGradient(starting: NSColor(srgbRed: 0.96, green: 0.57, blue: 0.34, alpha: 1),
                                  ending: NSColor(srgbRed: 0.83, green: 0.32, blue: 0.20, alpha: 1))!
        gradient.draw(in: tile, angle: -65)
        NSColor.white.withAlphaComponent(0.28).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 228, y: 228, width: 568, height: 568))
        ring.lineWidth = 26; ring.stroke()
        let pulse = NSBezierPath()
        pulse.move(to: NSPoint(x: 229, y: 510))
        for point in [NSPoint(x: 365, y: 510), NSPoint(x: 428, y: 650), NSPoint(x: 519, y: 369),
                      NSPoint(x: 606, y: 566), NSPoint(x: 656, y: 510), NSPoint(x: 795, y: 510)] {
            pulse.line(to: point)
        }
        pulse.lineWidth = 42; pulse.lineCapStyle = .round; pulse.lineJoinStyle = .round
        NSColor.white.setStroke(); pulse.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = factor == 2 ? "@2x" : ""
        let path = iconset.appendingPathComponent("icon_\(scale)x\(scale)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: path)
    }
}
let conversion = Process()
conversion.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
conversion.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AgentWatch.icns").path]
try conversion.run(); conversion.waitUntilExit()
guard conversion.terminationStatus == 0 else { exit(1) }
try FileManager.default.removeItem(at: iconset)
