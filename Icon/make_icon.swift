// Draws the Plex Peek app icon: an eye whose iris is a play button.
// Usage: swift Icon/make_icon.swift <output.png>
import AppKit

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func linear(_ colors: [CGColor], from: CGPoint, to: CGPoint, in path: CGPath) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [])
    ctx.restoreGState()
}

// Background tile (Apple's macOS grid: 824pt tile centered in 1024)
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x1C1C21))
ctx.fillPath()
ctx.restoreGState()
linear([rgb(0x3A3A42), rgb(0x151518)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100), in: tilePath)

// Eye outline (almond shape)
let c = CGPoint(x: 512, y: 512)
let halfW: CGFloat = 310, lift: CGFloat = 330
let eye = CGMutablePath()
eye.move(to: CGPoint(x: c.x - halfW, y: c.y))
eye.addQuadCurve(to: CGPoint(x: c.x + halfW, y: c.y), control: CGPoint(x: c.x, y: c.y + lift))
eye.addQuadCurve(to: CGPoint(x: c.x - halfW, y: c.y), control: CGPoint(x: c.x, y: c.y - lift))
eye.closeSubpath()

linear([rgb(0x2A2A31), rgb(0x1E1E23)], from: CGPoint(x: 512, y: 700), to: CGPoint(x: 512, y: 330), in: eye)

// Iris: Plex-style amber, clipped to the eye
let irisR: CGFloat = 132
let iris = CGPath(ellipseIn: CGRect(x: c.x - irisR, y: c.y - irisR, width: irisR * 2, height: irisR * 2), transform: nil)
ctx.saveGState()
ctx.addPath(eye)
ctx.clip()
ctx.setShadow(offset: .zero, blur: 40, color: rgb(0xE5A00D, 0.55))
ctx.addPath(iris)
ctx.setFillColor(rgb(0xE5A00D))
ctx.fillPath()
ctx.restoreGState()
linear([rgb(0xFFC93C), rgb(0xD9890A)], from: CGPoint(x: 512, y: c.y + irisR), to: CGPoint(x: 512, y: c.y - irisR), in: iris)

// Chevron inside the iris: a thick ">" with flat-cut ends at 45°
let halfH: CGFloat = 82, thick: CGFloat = 56
let x0 = c.x - (thick + halfH) / 2
let chevron = CGMutablePath()
chevron.move(to: CGPoint(x: x0, y: c.y + halfH))
chevron.addLine(to: CGPoint(x: x0 + thick, y: c.y + halfH))
chevron.addLine(to: CGPoint(x: x0 + thick + halfH, y: c.y))
chevron.addLine(to: CGPoint(x: x0 + thick, y: c.y - halfH))
chevron.addLine(to: CGPoint(x: x0, y: c.y - halfH))
chevron.addLine(to: CGPoint(x: x0 + halfH, y: c.y))
chevron.closeSubpath()
ctx.addPath(chevron)
ctx.setFillColor(rgb(0x1A1A1E))
ctx.fillPath()

// Eye outline stroke on top
ctx.addPath(eye)
ctx.setLineWidth(34)
ctx.setLineJoin(.round)
ctx.setStrokeColor(rgb(0xF2F2F5))
ctx.strokePath()

// Small glint
ctx.addEllipse(in: CGRect(x: c.x + 52, y: c.y + 60, width: 34, height: 34))
ctx.setFillColor(rgb(0xFFFFFF, 0.85))
ctx.fillPath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
