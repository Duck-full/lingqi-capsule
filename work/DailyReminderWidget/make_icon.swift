import AppKit
import Foundation

func gradient(_ colors: [NSColor], angle: CGFloat, rect: NSRect) -> NSGradient {
    NSGradient(colors: colors) ?? NSGradient(starting: colors.first ?? .black, ending: colors.last ?? .white)!
}

func path(_ points: [CGPoint]) -> NSBezierPath {
    let p = NSBezierPath()
    guard let first = points.first else { return p }
    p.move(to: first)
    points.dropFirst().forEach { p.line(to: $0) }
    p.close()
    return p
}

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = size / 1024.0
    let bounds = NSRect(x: 0, y: 0, width: size, height: size)
    NSGraphicsContext.current?.imageInterpolation = .high

    NSColor.clear.setFill()
    bounds.fill()

    let baseShadow = NSShadow()
    baseShadow.shadowColor = NSColor.black.withAlphaComponent(0.42)
    baseShadow.shadowBlurRadius = 42 * scale
    baseShadow.shadowOffset = NSSize(width: 0, height: -18 * scale)
    baseShadow.set()

    let baseRect = NSRect(x: 104 * scale, y: 96 * scale, width: 816 * scale, height: 816 * scale)
    let basePath = NSBezierPath(roundedRect: baseRect, xRadius: 190 * scale, yRadius: 190 * scale)
    gradient([
        NSColor(red: 0.07, green: 0.02, blue: 0.20, alpha: 1),
        NSColor(red: 0.22, green: 0.05, blue: 0.48, alpha: 1),
        NSColor(red: 0.04, green: 0.07, blue: 0.23, alpha: 1)
    ], angle: -42, rect: baseRect).draw(in: basePath, angle: -42)
    NSShadow().set()

    NSColor.white.withAlphaComponent(0.16).setStroke()
    basePath.lineWidth = max(2, 6 * scale)
    basePath.stroke()

    let glow = NSShadow()
    glow.shadowColor = NSColor(red: 0.17, green: 0.79, blue: 1.0, alpha: 0.55)
    glow.shadowBlurRadius = 34 * scale
    glow.shadowOffset = .zero
    glow.set()
    NSColor(red: 0.14, green: 0.72, blue: 1.0, alpha: 0.62).setStroke()
    let orbit = NSBezierPath(ovalIn: NSRect(x: 210 * scale, y: 258 * scale, width: 604 * scale, height: 438 * scale))
    orbit.lineWidth = max(3, 14 * scale)
    orbit.stroke()
    NSShadow().set()

    let cx = 512 * scale
    let cy = 500 * scale
    let top = path([
        CGPoint(x: cx, y: cy + 198 * scale),
        CGPoint(x: cx + 188 * scale, y: cy + 92 * scale),
        CGPoint(x: cx, y: cy - 8 * scale),
        CGPoint(x: cx - 188 * scale, y: cy + 92 * scale)
    ])
    let left = path([
        CGPoint(x: cx - 188 * scale, y: cy + 92 * scale),
        CGPoint(x: cx, y: cy - 8 * scale),
        CGPoint(x: cx, y: cy - 236 * scale),
        CGPoint(x: cx - 188 * scale, y: cy - 118 * scale)
    ])
    let right = path([
        CGPoint(x: cx + 188 * scale, y: cy + 92 * scale),
        CGPoint(x: cx, y: cy - 8 * scale),
        CGPoint(x: cx, y: cy - 236 * scale),
        CGPoint(x: cx + 188 * scale, y: cy - 118 * scale)
    ])

    let cubeShadow = NSShadow()
    cubeShadow.shadowColor = NSColor(red: 0.05, green: 0.02, blue: 0.16, alpha: 0.78)
    cubeShadow.shadowBlurRadius = 26 * scale
    cubeShadow.shadowOffset = NSSize(width: 0, height: -14 * scale)
    cubeShadow.set()
    gradient([NSColor(red: 0.43, green: 0.88, blue: 1, alpha: 1), NSColor(red: 0.45, green: 0.27, blue: 1, alpha: 1)], angle: 90, rect: bounds).draw(in: top, angle: 90)
    gradient([NSColor(red: 0.21, green: 0.31, blue: 1, alpha: 1), NSColor(red: 0.11, green: 0.06, blue: 0.42, alpha: 1)], angle: -30, rect: bounds).draw(in: left, angle: -30)
    gradient([NSColor(red: 0.20, green: 0.82, blue: 1, alpha: 1), NSColor(red: 0.24, green: 0.14, blue: 0.70, alpha: 1)], angle: 35, rect: bounds).draw(in: right, angle: 35)
    NSShadow().set()

    NSColor.white.withAlphaComponent(0.38).setStroke()
    [top, left, right].forEach {
        $0.lineWidth = max(2, 5 * scale)
        $0.stroke()
    }

    NSColor.white.withAlphaComponent(0.92).setFill()
    for row in 0..<3 {
        for col in 0..<3 {
            let x = CGFloat(438 + col * 52) * scale
            let y = CGFloat(454 - row * 46) * scale
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 24 * scale, height: 24 * scale), xRadius: 6 * scale, yRadius: 6 * scale).fill()
        }
    }

    let bellGlow = NSShadow()
    bellGlow.shadowColor = NSColor(red: 1.0, green: 0.67, blue: 0.25, alpha: 0.65)
    bellGlow.shadowBlurRadius = 20 * scale
    bellGlow.shadowOffset = .zero
    bellGlow.set()
    NSColor(red: 1.0, green: 0.68, blue: 0.28, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 648 * scale, y: 622 * scale, width: 104 * scale, height: 104 * scale)).fill()
    NSShadow().set()
    NSColor.white.setStroke()
    let tick = NSBezierPath()
    tick.lineWidth = max(4, 14 * scale)
    tick.lineCapStyle = .round
    tick.move(to: NSPoint(x: 682 * scale, y: 672 * scale))
    tick.line(to: NSPoint(x: 704 * scale, y: 650 * scale))
    tick.line(to: NSPoint(x: 724 * scale, y: 696 * scale))
    tick.stroke()

    for i in 0..<9 {
        let angle = CGFloat(i) * .pi * 2 / 9
        let x = cx + cos(angle) * 350 * scale
        let y = cy + sin(angle) * 270 * scale
        NSColor(red: 0.34, green: 0.88, blue: 1, alpha: i % 2 == 0 ? 0.9 : 0.42).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 8 * scale, y: y - 8 * scale, width: 16 * scale, height: 16 * scale)).fill()
    }

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not render icon PNG")
    }
    try! data.write(to: url)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let sizes: [(CGFloat, String)] = [
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
for (size, name) in sizes {
    savePNG(drawIcon(size: size), to: output.appendingPathComponent(name))
}
