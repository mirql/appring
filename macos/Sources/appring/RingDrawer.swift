import AppKit
import AppringCore

enum RingColors {
    static let tileTop = color("#2b2e38")
    static let tileBottom = color("#121318")
    static let text = color("#cdd6f4")
    static let palette = ["#e8c33a", "#d93a3a", "#4bbf2f", "#3a86e0", "#9d4fe6", "#e8792a", "#2ab3a3", "#e05fa5"].map(color)
    static let named = [
        "accent": "#b4a1db", "ok": "#a6e3a1", "warn": "#f9e2af", "error": "#f38ba8",
        "muted": "#6c7086", "dim": "#a6adc8", "text": "#cdd6f4",
    ].mapValues(color)

    static func slice(_ style: ButtonStyle, index: Int) -> NSColor {
        if style.glowColor == "auto" || style.glowColor.isEmpty {
            return palette[index % palette.count]
        }
        if let named = named[style.glowColor] { return named }
        if style.glowColor.hasPrefix("#") { return color(style.glowColor) }
        return palette[index % palette.count]
    }

    static func color(_ hex: String) -> NSColor {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = Int(text, radix: 16) else { return .white }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}

enum RingDrawer {
    static func draw(session: Session, icon: (Item) -> NSImage?, in rect: NSRect) {
        guard session.open else { return }
        let height = rect.height
        let centre = viewPoint(Vec(session.centreX, session.centreY), height: height)
        // Draw the centre before the buttons: in a satellite it sits on the group's button and would otherwise cover its icon.
        if let satellite = session.satellite {
            drawCentre(
                at: viewPoint(Vec(satellite.centreX, satellite.centreY), height: height),
                angle: satellite.deadZone ? nil : satellite.pointerAngle,
                color: satellite.highlighted >= 0 && satellite.highlighted < satellite.styles.count
                    ? RingColors.slice(satellite.styles[satellite.highlighted], index: satellite.highlighted) : .white,
                active: !satellite.deadZone && satellite.highlighted >= 0,
                scale: session.appearance.scale * 0.8
            )
        }
        let active = !session.deadZone && session.highlighted >= 0 && session.highlighted < session.styles.count
        drawCentre(
            at: centre,
            angle: session.deadZone ? nil : session.pointerAngle,
            color: active ? RingColors.slice(session.styles[session.highlighted], index: session.highlighted) : .white,
            active: active,
            scale: session.appearance.scale
        )
        if let satellite = session.satellite {
            drawRing(
                items: session.items,
                styles: session.styles,
                highlighted: satellite.parentIndex,
                centre: centre,
                dimmed: true,
                icon: icon,
                height: height,
                enlarge: session.appearance.highlightScale
            )
            drawRing(
                items: satellite.items,
                styles: satellite.styles,
                highlighted: satellite.deadZone ? -1 : satellite.highlighted,
                centre: viewPoint(Vec(satellite.centreX, satellite.centreY), height: height),
                dimmed: false,
                icon: icon,
                height: height,
                enlarge: session.appearance.highlightScale
            )
        } else {
            drawRing(
                items: session.items,
                styles: session.styles,
                highlighted: session.deadZone ? -1 : session.highlighted,
                centre: centre,
                dimmed: false,
                icon: icon,
                height: height,
                enlarge: session.appearance.highlightScale
            )
        }
    }

    private static func drawRing(items: [Item], styles: [ButtonStyle], highlighted: Int, centre: NSPoint, dimmed: Bool, icon: (Item) -> NSImage?, height: CGFloat, enlarge: Double) {
        guard !items.isEmpty else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        if dimmed { NSGraphicsContext.current?.cgContext.setAlpha(0.4) }
        for index in items.indices {
            let style = styles[index]
            let model = buttonCenter(index: index, count: items.count, centre: Vec(0, 0), radius: style.ringRadius)
            // buttonCenter is from (0, 0): x to the right, y down. In the view y is up, so y changes sign.
            let point = NSPoint(x: centre.x + CGFloat(model.x), y: centre.y - CGFloat(model.y))
            let selected = index == highlighted
            drawButton(
                at: point,
                style: style,
                color: RingColors.slice(style, index: index),
                selected: selected,
                enlarge: enlarge,
                image: icon(items[index]),
                label: items[index].label,
                group: items[index].isGroup,
                from: centre
            )
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private static func drawButton(at point: NSPoint, style: ButtonStyle, color: NSColor, selected: Bool, enlarge: Double, image: NSImage?, label: String, group: Bool, from centre: NSPoint) {
        let scale: CGFloat = selected ? CGFloat(enlarge) : 1
        let size = CGFloat(style.size) * scale
        let rect = NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        let path = buttonPath(rect, style: style, size: size)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = selected ? 16 : 8
        shadow.shadowColor = (selected ? color : NSColor.black).withAlphaComponent(selected ? 0.85 : 0.45)
        shadow.shadowOffset = .zero
        shadow.set()
        if selected {
            color.withAlphaComponent(0.35).setFill()
            buttonPath(rect.insetBy(dx: -CGFloat(style.glowSize), dy: -CGFloat(style.glowSize)), style: style, size: size + CGFloat(style.glowSize) * 2).fill()
        }
        path.addClip()
        NSGradient(colors: [RingColors.tileTop, RingColors.tileBottom])?.draw(in: rect, angle: -90)
        NSGraphicsContext.current?.restoreGraphicsState()
        color.setStroke()
        path.lineWidth = selected ? 2.5 : 1.5
        path.stroke()
        if let image {
            let inset = max(6, size * 0.18)
            image.draw(in: rect.insetBy(dx: inset, dy: inset), from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            let letter = String(label.prefix(1)).uppercased()
            let font = NSFont.systemFont(ofSize: size * 0.36, weight: .medium)
            let text = NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: RingColors.text])
            let textSize = text.size()
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
        }
        if group {
            let mark = NSBezierPath(ovalIn: NSRect(x: point.x + size / 2 - 8, y: point.y + size / 2 - 8, width: 7, height: 7))
            color.setFill()
            mark.fill()
        }
        let showCaption = style.caption == "all" || (style.caption == "selected" && selected)
        if showCaption {
            drawCaption(label, at: point, from: centre, size: size, fontSize: CGFloat(max(style.captionSize, 11)))
        }
    }

    private static func drawCaption(_ label: String, at point: NSPoint, from centre: NSPoint, size: CGFloat, fontSize: CGFloat) {
        let dx = point.x - centre.x
        let dy = point.y - centre.y
        let length = max(hypot(dx, dy), 1)
        let place = NSPoint(x: point.x + dx / length * (size / 2 + 16), y: point.y + dy / length * (size / 2 + 16))
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let text = NSAttributedString(string: label, attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black.withAlphaComponent(0.9),
            .strokeWidth: -3,
        ])
        let textSize = text.size()
        text.draw(at: NSPoint(x: place.x - textSize.width / 2, y: place.y - textSize.height / 2))
    }

    private static func drawCentre(at point: NSPoint, angle: Double?, color: NSColor, active: Bool, scale: Double) {
        let outer = CGFloat(31 * scale)
        let width = CGFloat(7.5 * scale)
        let rect = NSRect(x: point.x - outer, y: point.y - outer, width: outer * 2, height: outer * 2)
        let ring = NSBezierPath(ovalIn: rect)
        ring.lineWidth = width
        color.withAlphaComponent(active ? 0.9 : 0.35).setStroke()
        ring.stroke()
        guard let angle else { return }
        let radians = CGFloat(angle * .pi / 180)
        let distance = CGFloat(66 * scale)
        let tip = NSPoint(x: point.x + sin(radians) * distance, y: point.y + cos(radians) * distance)
        let back = CGFloat(14 * scale)
        let arm = CGFloat(9 * scale)
        let base = NSPoint(x: point.x + sin(radians) * (distance - back), y: point.y + cos(radians) * (distance - back))
        let px = cos(radians)
        let py = -sin(radians)
        let chevron = NSBezierPath()
        chevron.move(to: tip)
        chevron.line(to: NSPoint(x: base.x + px * arm, y: base.y + py * arm))
        chevron.line(to: NSPoint(x: base.x - px * arm, y: base.y - py * arm))
        chevron.close()
        color.withAlphaComponent(active ? 0.95 : 0.2).setFill()
        chevron.fill()
    }

    private static func buttonPath(_ rect: NSRect, style: ButtonStyle, size: CGFloat) -> NSBezierPath {
        if style.shape == "circle" {
            return NSBezierPath(ovalIn: rect)
        }
        let radius = min(size / 2, size * CGFloat(style.cornerRadius))
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    private static func viewPoint(_ model: Vec, height: CGFloat) -> NSPoint {
        NSPoint(x: model.x, y: height - model.y)
    }
}

final class RingView: NSView {
    var session = Session()
    var icon: (Item) -> NSImage? = { _ in nil }
    weak var actions: RingActions?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        RingDrawer.draw(session: session, icon: icon, in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        // The click's own point, on the screen: the pointer may have moved on since the click.
        let point = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        actions?.ringCommit(at: point)
    }

    override func rightMouseDown(with event: NSEvent) {
        actions?.ringCancel()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            actions?.ringCancel()
            return
        }
    }
}

protocol RingActions: AnyObject {
    func ringCommit(at screenPoint: NSPoint)
    func ringCancel()
}
