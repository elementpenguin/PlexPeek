import AppKit

/// Menu bar version of the app icon: an eye with a chevron pupil.
/// Drawn as a template image so macOS tints it for light/dark menu bars.
enum MenuBarIcon {
    static let idle = make(active: false)
    static let active = make(active: true)

    static func make(active: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let c = CGPoint(x: size.width / 2, y: size.height / 2)

            // Almond eye outline
            let halfW: CGFloat = 9, lift: CGFloat = 13
            let eye = CGMutablePath()
            eye.move(to: CGPoint(x: c.x - halfW, y: c.y))
            eye.addQuadCurve(to: CGPoint(x: c.x + halfW, y: c.y), control: CGPoint(x: c.x, y: c.y + lift))
            eye.addQuadCurve(to: CGPoint(x: c.x - halfW, y: c.y), control: CGPoint(x: c.x, y: c.y - lift))
            eye.closeSubpath()
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineJoin(.round)
            ctx.addPath(eye)
            ctx.strokePath()

            // Chevron pupil
            let halfH: CGFloat = active ? 2.6 : 3.2
            let thick: CGFloat = active ? 1.7 : 1.9
            let x0 = c.x - (thick + halfH) / 2
            let chevron = CGMutablePath()
            chevron.move(to: CGPoint(x: x0, y: c.y + halfH))
            chevron.addLine(to: CGPoint(x: x0 + thick, y: c.y + halfH))
            chevron.addLine(to: CGPoint(x: x0 + thick + halfH, y: c.y))
            chevron.addLine(to: CGPoint(x: x0 + thick, y: c.y - halfH))
            chevron.addLine(to: CGPoint(x: x0, y: c.y - halfH))
            chevron.addLine(to: CGPoint(x: x0 + halfH, y: c.y))
            chevron.closeSubpath()

            if active {
                // Solid iris with the chevron knocked out of it
                let r: CGFloat = 4.3
                ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                ctx.setBlendMode(.destinationOut)
                ctx.addPath(chevron)
                ctx.fillPath()
                ctx.setBlendMode(.normal)
            } else {
                ctx.addPath(chevron)
                ctx.fillPath()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
