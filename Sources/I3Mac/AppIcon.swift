// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mac-i3 contributors

import AppKit

/// The mac-i3 icon: a rounded square holding a small tiling layout (one tall window beside two stacked ones,
/// the focused one highlighted, each with an i3-style title bar). Drawn in code so every size is crisp and the
/// menu bar glyph shares the same shapes.
public enum AppIcon {
    private static func color(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }

    /// Frames of the three panes inside `area`: tall on the left, two stacked on the right (top one focused).
    private static func panes(in area: NSRect) -> (left: NSRect, topRight: NSRect, bottomRight: NSRect) {
        let gap = area.width * 0.075
        let leftW = (area.width - gap) * 0.47
        let rightW = area.width - gap - leftW
        let rightH = (area.height - gap) / 2
        let left = NSRect(x: area.minX, y: area.minY, width: leftW, height: area.height)
        let bottomRight = NSRect(x: area.minX + leftW + gap, y: area.minY, width: rightW, height: rightH)
        let topRight = NSRect(x: bottomRight.minX, y: area.minY + rightH + gap, width: rightW, height: rightH)
        return (left, topRight, bottomRight)
    }

    /// Draws the icon into the current graphics context, filling a `size` x `size` square at the origin.
    static func draw(size s: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let inset = s * 0.0977                                   // Apple's icon grid: 824pt body on a 1024pt canvas
        let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.2237, yRadius: body.width * 0.2237)

        ctx.saveGState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = s * 0.022
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
        shadow.set()
        color(0x1a2a38).setFill()
        path.fill()
        ctx.restoreGState()

        NSGradient(starting: color(0x3a5a75), ending: color(0x152230))?.draw(in: path, angle: -90)
        color(0xffffff, 0.14).setStroke()                        // a hairline of light along the edge
        path.lineWidth = max(1, s * 0.004)
        path.stroke()

        let detailed = s >= 64
        let area = body.insetBy(dx: body.width * 0.135, dy: body.height * 0.135)
        let p = panes(in: area)
        let radius = area.width * 0.07
        let titleBar = area.width * 0.10

        func pane(_ r: NSRect, focused: Bool) {
            let shape = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
            if detailed {
                (focused ? color(0x23485f) : color(0xffffff, 0.09)).setFill()
                shape.fill()
                ctx.saveGState()                                 // title bar: the top strip of the pane
                shape.addClip()
                (focused ? color(0x5aa9e6) : color(0xffffff, 0.30)).setFill()
                NSRect(x: r.minX, y: r.maxY - titleBar, width: r.width, height: titleBar).fill()
                ctx.restoreGState()
                (focused ? color(0x8ccbf7) : color(0xffffff, 0.24)).setStroke()
                shape.lineWidth = max(1, area.width * (focused ? 0.022 : 0.012))
                shape.stroke()
            } else {                                             // tiny sizes: just solid tiles
                (focused ? color(0x5aa9e6) : color(0xffffff, 0.34)).setFill()
                shape.fill()
            }
        }
        pane(p.left, focused: false)
        pane(p.bottomRight, focused: false)
        pane(p.topRight, focused: true)
    }

    /// PNG data for the icon at an exact pixel size.
    public static func png(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        draw(size: CGFloat(pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Writes an `.iconset` folder (input for `iconutil -c icns`).
    public static func writeIconset(to dir: String) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sizes: [(name: String, px: Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, px) in sizes {
            guard let data = png(pixels: px), (try? data.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))) != nil else { return false }
        }
        return true
    }

    /// The same three-pane layout as a monochrome menu bar glyph (a template image, so macOS tints it).
    public static func menuBarImage() -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            let p = panes(in: rect.insetBy(dx: 1.5, dy: 1.5))
            NSColor.black.setFill()
            NSColor.black.setStroke()
            for r in [p.left, p.bottomRight] {
                let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.7, dy: 0.7), xRadius: 2, yRadius: 2)
                path.lineWidth = 1.4
                path.stroke()
            }
            NSBezierPath(roundedRect: p.topRight, xRadius: 2, yRadius: 2).fill()      // the focused pane is solid
            return true
        }
        img.isTemplate = true
        return img
    }
}
