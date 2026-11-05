import AppKit

// Original Agent Watch artwork: the camera housing with a status strip hanging below it.
// The three dots use the app's running, waiting-approval and ended colors.
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources")
let iconset = output.appendingPathComponent("AgentWatch.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func draw() {
    let tileRect = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0, 0, 0, 0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0.1, 0.1, 0.12).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(starting: color(0.2, 0.21, 0.25), ending: color(0.07, 0.075, 0.09))!.draw(in: tileRect, angle: -90)

    // Camera housing attached to the top edge.
    let notch = NSBezierPath()
    let notchRect = NSRect(x: 352, y: 812, width: 320, height: 140)
    let radius: CGFloat = 52
    notch.move(to: NSPoint(x: notchRect.minX, y: notchRect.maxY))
    notch.line(to: NSPoint(x: notchRect.minX, y: notchRect.minY + radius))
    notch.appendArc(withCenter: NSPoint(x: notchRect.minX + radius, y: notchRect.minY + radius), radius: radius,
                    startAngle: 180, endAngle: 270)
    notch.line(to: NSPoint(x: notchRect.maxX - radius, y: notchRect.minY))
    notch.appendArc(withCenter: NSPoint(x: notchRect.maxX - radius, y: notchRect.minY + radius), radius: radius,
                    startAngle: 270, endAngle: 360)
    notch.line(to: NSPoint(x: notchRect.maxX, y: notchRect.maxY))
    notch.close()
    NSColor.black.setFill()
    notch.fill()
    color(0.16, 0.17, 0.2).setFill()
    NSBezierPath(ovalIn: NSRect(x: 588, y: 852, width: 30, height: 30)).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Status strip.
    let stripRect = NSRect(x: 192, y: 470, width: 640, height: 230)
    let strip = NSBezierPath(roundedRect: stripRect, xRadius: 115, yRadius: 115)
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color(0, 0, 0, 0.55)
    glow.shadowBlurRadius = 40
    glow.shadowOffset = NSSize(width: 0, height: -16)
    glow.set()
    color(0.03, 0.035, 0.045).setFill()
    strip.fill()
    NSGraphicsContext.restoreGraphicsState()
    color(1, 1, 1, 0.1).setStroke()
    strip.lineWidth = 4
    strip.stroke()

    let dots = [color(0.24, 0.52, 0.91), color(0.91, 0.43, 0.25), color(0.25, 0.59, 0.43)]
    let diameter: CGFloat = 124
    let gap: CGFloat = 54
    let startX = stripRect.midX - (diameter * 3 + gap * 2) / 2
    for (index, dot) in dots.enumerated() {
        let rect = NSRect(x: startX + CGFloat(index) * (diameter + gap), y: stripRect.midY - diameter / 2,
                          width: diameter, height: diameter)
        NSGraphicsContext.saveGraphicsState()
        let halo = NSShadow()
        halo.shadowColor = dot.withAlphaComponent(0.6)
        halo.shadowBlurRadius = 34
        halo.set()
        dot.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSGraphicsContext.restoreGraphicsState()
        // A soft highlight keeps the dots from looking flat at large sizes.
        NSGradient(starting: color(1, 1, 1, 0.28), ending: color(1, 1, 1, 0))!
            .draw(in: NSBezierPath(ovalIn: rect), angle: -90)
    }
}

for scale in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let pixels = scale * factor
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        draw()
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
