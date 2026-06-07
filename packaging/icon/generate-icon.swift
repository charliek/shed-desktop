// generate-icon.swift — render the app icon master (1024×1024 PNG).
//
// Reuses the menu-bar glyph (an SF Symbol) on a rounded-square background, so
// the Dock/Finder icon matches the status-item. Recolor via --bg / --fg.
// Usage: swift generate-icon.swift --out master.png [--bg 4F759A] [--fg FFFFFF] [--symbol shippingbox.fill]

import AppKit
import Foundation

var outPath = "master.png"
var bgHex = "4F759A"   // slate-blue accent (placeholder brand color)
var fgHex = "FFFFFF"
var symbol = "shippingbox.fill"

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--out": outPath = args[i + 1]; i += 2
    case "--bg": bgHex = args[i + 1]; i += 2
    case "--fg": fgHex = args[i + 1]; i += 2
    case "--symbol": symbol = args[i + 1]; i += 2
    default: outPath = args[i]; i += 1
    }
}

func color(_ hex: String) -> NSColor {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    let v = UInt32(s, radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                   green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

let size = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    FileHandle.standardError.write(Data("rep alloc failed\n".utf8)); exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let s = CGFloat(size)
// Rounded-square body with the standard macOS margin + corner radius.
let margin = s * 0.0977
let body = NSRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
color(bgHex).set()
NSBezierPath(roundedRect: body, xRadius: body.width * 0.2237, yRadius: body.width * 0.2237).fill()

// Centered glyph, tinted via a palette color.
let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [color(fgHex)]))
if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let g = glyph.size
    glyph.draw(at: NSPoint(x: (s - g.width) / 2, y: (s - g.height) / 2),
               from: .zero, operation: .sourceOver, fraction: 1)
} else {
    FileHandle.standardError.write(Data("symbol \(symbol) not found\n".utf8)); exit(1)
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("png encode failed\n".utf8)); exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
