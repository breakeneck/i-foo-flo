// Build-time icon generator: composites ~/dev/foobar-qt/musical-note.png
// (black glyph) onto a rounded blue gradient tile, white-tinted — same
// design as appicon.py. Writes AppIcon.icns into the bundle.
//
// swift makeicon.swift <glyph.png> <out.icns>

import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let glyph = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("icon: cannot load glyph\n".data(using: .utf8)!)
    exit(1)
}

let sizes = [16, 32, 64, 128, 256, 512]
let tmp = NSTemporaryDirectory() + "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: tmp)
try! FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)

func render(_ px: Int) -> NSImage {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let rect = CGRect(x: 0, y: 0, width: px, height: px).insetBy(dx: CGFloat(px) * 0.08, dy: CGFloat(px) * 0.08)
    let radius = rect.width * 0.22
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path); ctx.clip()
    let colors = [CGColor(red: 0x4a/255, green: 0x90/255, blue: 0xd9/255, alpha: 1),
                  CGColor(red: 0x2c/255, green: 0x6f/255, blue: 0xb0/255, alpha: 1)]
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    // white-tinted glyph, centered, 55% of tile
    let g = glyph.size
    let scale = rect.width * 0.55 / max(g.width, g.height)
    let w = g.width * scale, h = g.height * scale
    let dest = CGRect(x: rect.midX - w/2, y: rect.midY - h/2, width: w, height: h)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: dest, cornerWidth: 0, cornerHeight: 0, transform: nil))
    ctx.clip(to: dest)
    glyph.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1)
    // tint: source-in white
    NSColor.white.set()
    ctx.setBlendMode(.sourceAtop)
    ctx.fill(dest)
    ctx.restoreGState()
    img.unlockFocus()
    return img
}

func png(_ img: NSImage, _ px: Int, _ file: String) {
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else { return }
    try! data.write(to: URL(fileURLWithPath: "\(tmp)/\(file)"))
}

for s in sizes {
    png(render(s), s, "icon_\(s)x\(s).png")
    if s * 2 <= 1024 { png(render(s * 2), s * 2, "icon_\(s)x\(s)@2x.png") }
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", "-o", args[2], tmp]
try! proc.run()
proc.waitUntilExit()
exit(proc.terminationStatus)