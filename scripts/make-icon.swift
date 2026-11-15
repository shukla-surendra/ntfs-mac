// Renders the app icon. Usage: swift scripts/make-icon.swift <output.iconset dir>
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = s / 1024

    // Background squircle with margin (macOS icon grid: ~824pt body in 1024)
    let body = NSRect(x: 100*u, y: 100*u, width: 824*u, height: 824*u)
    let bg = NSBezierPath(roundedRect: body, xRadius: 185*u, yRadius: 185*u)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.55, blue: 0.98, alpha: 1),
                        NSColor(red: 0.06, green: 0.22, blue: 0.62, alpha: 1)])!.draw(in: bg, angle: -90)

    // Recenter the glyph group within the tile
    let t = NSAffineTransform(); t.translateX(by: 0, yBy: -92*u); t.concat()

    // Drive body
    let drive = NSRect(x: 220*u, y: 330*u, width: 584*u, height: 300*u)
    let dp = NSBezierPath(roundedRect: drive, xRadius: 48*u, yRadius: 48*u)
    NSGraphicsContext.current?.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35)
    sh.shadowOffset = NSSize(width: 0, height: -14*u); sh.shadowBlurRadius = 30*u; sh.set()
    NSGradient(colors: [.white, NSColor(white: 0.84, alpha: 1)])!.draw(in: dp, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Drive details: activity LED and vent lines
    NSColor(red: 0.18, green: 0.80, blue: 0.44, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 258*u, y: 372*u, width: 44*u, height: 44*u)).fill()
    NSColor(white: 0.62, alpha: 1).setFill()
    for i in 0..<5 {
        NSBezierPath(roundedRect: NSRect(x: (520 + CGFloat(i)*50)*u, y: 372*u, width: 24*u, height: 44*u),
                     xRadius: 8*u, yRadius: 8*u).fill()
    }

    // Read/write arrows above the drive
    NSColor.white.setStroke(); NSColor.white.setFill()
    func arrow(x: CGFloat, up: Bool) {
        let y0: CGFloat = up ? 670 : 860, y1: CGFloat = up ? 860 : 670
        let line = NSBezierPath(); line.lineWidth = 34*u; line.lineCapStyle = .round
        line.move(to: NSPoint(x: x*u, y: y0*u)); line.line(to: NSPoint(x: x*u, y: (y1 + (up ? -40 : 40))*u)); line.stroke()
        let h = NSBezierPath(); let d: CGFloat = up ? 1 : -1
        h.move(to: NSPoint(x: x*u, y: y1*u))
        h.line(to: NSPoint(x: (x-60)*u, y: (y1 - 70*d)*u)); h.line(to: NSPoint(x: (x+60)*u, y: (y1 - 70*d)*u)); h.close(); h.fill()
    }
    arrow(x: 400, up: false)   // read: data comes down from drive side
    arrow(x: 624, up: true)    // write

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, px) in [("16",16),("16@2x",32),("32",32),("32@2x",64),("128",128),("128@2x",256),
                   ("256",256),("256@2x",512),("512",512),("512@2x",1024)] {
    try render(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name.replacingOccurrences(of: "@2x", with: ""))x\(name.replacingOccurrences(of: "@2x", with: ""))\(name.contains("@2x") ? "@2x" : "").png"))
}
