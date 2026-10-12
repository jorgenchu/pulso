import AppKit

/// Draws status item contents as template images, so the system tints them to
/// match the menu bar (light, dark, or over a wallpaper).
enum MenuBarRenderer {
    static let height = Metrics.menuBarItemHeight

    private static let labelFont = NSFont.systemFont(ofSize: 8.5, weight: .bold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
    private static let stackedFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let stackedLineHeight: CGFloat = 10
    private static let gap: CGFloat = 4
    /// Opacity of the tag, and of the part of a glyph that is not the reading.
    private static let labelAlpha: CGFloat = 0.7
    private static let dimAlpha: CGFloat = 0.35

    static func image(for content: MenuBarContent) -> NSImage {
        let image: NSImage
        switch content {
        case let .value(label, glyph, text, widest):
            image = valueImage(label: label, glyph: glyph, text: text, widest: widest)
        case let .stacked(top, bottom, widest):
            image = stackedImage(top: top, bottom: bottom, widest: widest)
        }
        image.isTemplate = true
        return image
    }

    // In a template image only the alpha channel matters; black is just the carrier.
    private static func ink(_ alpha: CGFloat = 1) -> NSColor {
        NSColor.black.withAlphaComponent(alpha)
    }

    private static func string(_ text: String, font: NSFont, alpha: CGFloat = 1, kern: CGFloat = 0) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink(alpha), .kern: kern])
    }

    private static func valueImage(label: String?, glyph: MenuBarContent.Glyph?, text: String, widest: String) -> NSImage {
        let label = label.map { string($0, font: labelFont, alpha: labelAlpha, kern: 0.17) }
        let value = string(text, font: valueFont)
        let labelSize = label?.size() ?? .zero, valueSize = value.size(), glyphSize = glyph.map(extent) ?? .zero
        let valueWidth = max(valueSize.width, string(widest, font: valueFont).size().width)
        let leading = [labelSize.width, glyphSize.width].filter { $0 > 0 }.reduce(0) { $0 + $1 + gap }
        let width = ceil(leading + valueWidth)

        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            if let label {
                label.draw(at: NSPoint(x: x, y: (height - labelSize.height) / 2))
                x += labelSize.width + gap
            }
            if let glyph {
                draw(glyph, at: NSPoint(x: x, y: (height - glyphSize.height) / 2))
                x += glyphSize.width + gap
            }
            value.draw(at: NSPoint(x: x + valueWidth - valueSize.width, y: (height - valueSize.height) / 2))
            return true
        }
    }

    private static func stackedImage(top: String, bottom: String, widest: String) -> NSImage {
        let top = string(top, font: stackedFont), bottom = string(bottom, font: stackedFont)
        let topSize = top.size(), bottomSize = bottom.size()
        let width = ceil(max(topSize.width, bottomSize.width, string(widest, font: stackedFont).size().width))
        // Two lines of fixed height, centred together.
        let bottomEdge = (height - 2 * stackedLineHeight) / 2

        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            top.draw(at: NSPoint(x: width - topSize.width,
                                 y: bottomEdge + stackedLineHeight + (stackedLineHeight - topSize.height) / 2))
            bottom.draw(at: NSPoint(x: width - bottomSize.width, y: bottomEdge + (stackedLineHeight - bottomSize.height) / 2))
            return true
        }
    }

    // MARK: Glyphs

    private static func extent(of glyph: MenuBarContent.Glyph) -> NSSize {
        switch glyph {
        case let .bars(_, slots):
            // 2 pt bars 1 pt apart, standing on a 1 pt baseline.
            return NSSize(width: CGFloat(slots * 3 - 1), height: CGFloat(MenuBarContent.Glyph.barHeight + 2))
        case .pill:
            return NSSize(width: MenuBarContent.Glyph.pillWidth, height: 8)
        case .battery:
            return NSSize(width: 24, height: 11)
        }
    }

    /// `origin` is the bottom left corner of the glyph.
    private static func draw(_ glyph: MenuBarContent.Glyph, at origin: NSPoint) {
        let size = extent(of: glyph)
        switch glyph {
        case let .bars(heights, slots):
            ink(dimAlpha).setFill()
            NSRect(x: origin.x, y: origin.y, width: size.width, height: 1).fill()
            ink().setFill()
            // The last bar is at the right edge; a short history leaves the left empty.
            var x = origin.x + CGFloat(slots - heights.count) * 3
            for barHeight in heights {
                NSRect(x: x, y: origin.y + 1, width: 2, height: CGFloat(barHeight)).fill()
                x += 3
            }
        case let .pill(filled):
            func pill(_ width: CGFloat) -> NSBezierPath {
                NSBezierPath(roundedRect: NSRect(x: origin.x, y: origin.y, width: width, height: size.height),
                             xRadius: size.height / 2, yRadius: size.height / 2)
            }
            ink(dimAlpha).setFill()
            pill(size.width).fill()
            if filled > 0 {
                ink().setFill()
                // The filled end stays round, so it is never narrower than the pill is tall.
                pill(max(size.height, filled)).fill()
            }
        case let .battery(filled):
            let body = NSBezierPath(roundedRect: NSRect(x: origin.x, y: origin.y, width: 21, height: 11), xRadius: 2, yRadius: 2)
            body.append(NSBezierPath(roundedRect: NSRect(x: origin.x + 1, y: origin.y + 1, width: 19, height: 9),
                                     xRadius: 1, yRadius: 1))
            body.windingRule = .evenOdd
            let cap = NSBezierPath()
            cap.move(to: NSPoint(x: origin.x + 22, y: origin.y + 3.5))
            cap.line(to: NSPoint(x: origin.x + 22.5, y: origin.y + 3.5))
            cap.appendArc(withCenter: NSPoint(x: origin.x + 22.5, y: origin.y + 4.5), radius: 1, startAngle: 270, endAngle: 0)
            cap.line(to: NSPoint(x: origin.x + 23.5, y: origin.y + 6.5))
            cap.appendArc(withCenter: NSPoint(x: origin.x + 22.5, y: origin.y + 6.5), radius: 1, startAngle: 0, endAngle: 90)
            cap.line(to: NSPoint(x: origin.x + 22, y: origin.y + 7.5))
            cap.close()
            ink(dimAlpha).setFill()
            body.fill()
            cap.fill()
            ink().setFill()
            NSRect(x: origin.x + 2.5, y: origin.y + 2.5, width: filled, height: 6).fill()
        }
    }
}
