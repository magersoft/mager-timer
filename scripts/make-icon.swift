// Draws the app icon: a day-progress ring with a dollar sign, on the macOS icon grid.
// Usage: swift scripts/make-icon.swift <out.png>   (1024×1024)
import AppKit

let size = 1024.0
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

func rgb(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
  CGColor(srgbRed: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
          blue: Double(hex & 0xFF) / 255, alpha: alpha)
}

func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> CGColor {
  func ch(_ v: UInt32, _ s: UInt32) -> Double { Double(v >> s & 0xFF) / 255 }
  let l = { (s: UInt32) in ch(a, s) + (ch(b, s) - ch(a, s)) * t }
  return CGColor(srgbRed: l(16), green: l(8), blue: l(0), alpha: 1)
}

let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Body: 824 pt rounded square centred on the 1024 canvas, as in Apple's macOS icon template.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(shape)
ctx.setFillColor(rgb(0x0E1F33))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let bg = CGGradient(colorsSpace: nil, colors: [rgb(0x1D4E5F), rgb(0x0E1F33)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
let glow = CGGradient(colorsSpace: nil, colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 860), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 860), endRadius: 520, options: [])
ctx.restoreGState()

let center = CGPoint(x: 512, y: 492)
let radius = 270.0
let width = 74.0

// Stopwatch crown above the ring.
ctx.setFillColor(rgb(0xE8EEF2))
ctx.addPath(CGPath(roundedRect: CGRect(x: 512 - 46, y: center.y + radius + width / 2 + 18, width: 92, height: 44),
                   cornerWidth: 16, cornerHeight: 16, transform: nil))
ctx.fillPath()
ctx.fill(CGRect(x: 512 - 16, y: center.y + radius + width / 2 - 4, width: 32, height: 26))

// Ring track.
ctx.setLineWidth(width)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.13))
ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.strokePath()

// Progress: three quarters of the day, from 12 o'clock clockwise, mint fading into gold.
let from = 0x34D399 as UInt32, to = 0xFBBF24 as UInt32
let start = Double.pi / 2, sweep = Double.pi * 2 * 0.75
let steps = 240
ctx.setLineCap(.butt)
for i in 0..<steps {
  let a0 = start - sweep * Double(i) / Double(steps)
  let a1 = start - sweep * Double(i + 1) / Double(steps) - 0.004
  ctx.setStrokeColor(mix(from, to, Double(i) / Double(steps - 1)))
  ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: true)
  ctx.strokePath()
}
for (angle, color) in [(start, mix(from, to, 0)), (start - sweep, mix(from, to, 1))] {
  ctx.setFillColor(color)
  let p = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
  ctx.fillEllipse(in: CGRect(x: p.x - width / 2, y: p.y - width / 2, width: width, height: width))
}

// Dollar sign in the middle.
let base = NSFont.systemFont(ofSize: 300, weight: .heavy)
let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: 300) ?? base
let text = NSAttributedString(string: "$", attributes: [.font: font, .foregroundColor: NSColor.white])
let line = CTLineCreateWithAttributedString(text)
let glyph = CTLineGetImageBounds(line, ctx)
ctx.textPosition = CGPoint(x: center.x - glyph.midX, y: center.y - glyph.midY)
CTLineDraw(line, ctx)

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: URL(filePath: out))
print("Wrote \(out)")
