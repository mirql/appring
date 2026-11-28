import Foundation

// Angles as in Radial.qml: 0 is up, clockwise. The y axis points down.
public func sliceOf(dx: Double, dy: Double, count: Int, gap: Double) -> (angle: Double, index: Int) {
    guard count > 0 else { return (0, -1) }
    let angle = positiveDegrees(atan2(dx, -dy) * 180 / .pi)
    let sliceWidth = 360.0 / Double(count)
    let shifted = positiveDegrees(angle + sliceWidth / 2)
    let idx = Int(floor(shifted / sliceWidth)) % count
    var off = abs(angle - Double(idx) * sliceWidth)
    if off > 180 { off = 360 - off }
    let inGap = count > 1 && off > sliceWidth / 2 * (1 - gap)
    return (angle, inGap ? -1 : idx)
}

public func buttonCenter(index: Int, count: Int, centre: Vec, radius: Double) -> Vec {
    guard count > 0 else { return centre }
    let angle = Double(index) * (360.0 / Double(count)) * .pi / 180
    return Vec(x: centre.x + radius * sin(angle), y: centre.y - radius * cos(angle))
}

public struct Vec: Equatable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

private func positiveDegrees(_ value: Double) -> Double {
    let wrapped = value.truncatingRemainder(dividingBy: 360)
    return wrapped < 0 ? wrapped + 360 : wrapped
}

public enum StyleValue: Equatable {
    case text(String)
    case number(Double)
    case flag(Bool)
}

public struct Item: Equatable {
    public var label: String
    public var icon: String
    public var run: [String]
    public var items: [Item]
    public var style: [String: StyleValue]

    public var isGroup: Bool { !items.isEmpty }

    public init(label: String, icon: String = "", run: [String] = [], items: [Item] = [], style: [String: StyleValue] = [:]) {
        self.label = label
        self.icon = icon
        self.run = run
        self.items = items
        self.style = style
    }
}

public struct ButtonStyle: Equatable {
    public var shape: String
    public var cornerRadius: Double
    public var size: Double
    public var glowColor: String
    public var glowSize: Double
    public var ringRadius: Double
    public var caption: String
    public var captionSize: Double
    public var backdrop: Bool

    public static func base(count: Int, satellite: Bool, appearance: Appearance) -> ButtonStyle {
        let factor = satellite ? 0.8 : 1.0
        return ButtonStyle(
            shape: "rounded-square",
            cornerRadius: 0.14,
            size: (48 * appearance.scale * factor).rounded(),
            glowColor: "auto",
            glowSize: (10 * appearance.scale * factor).rounded(),
            ringRadius: appearance.ringRadius(count: count, satellite: satellite),
            caption: appearance.labels,
            captionSize: (11 * appearance.scale * factor).rounded(),
            backdrop: false
        )
    }

    public mutating func apply(_ values: [String: StyleValue]) {
        for (key, value) in values {
            switch key {
            case "shape":
                if case .text(let text) = value { shape = text }
            case "cornerRadius":
                if case .number(let number) = value { cornerRadius = number }
            case "size":
                if case .number(let number) = value { size = number }
            case "glowColor":
                if case .text(let text) = value { glowColor = text }
            case "glowSize":
                if case .number(let number) = value { glowSize = number }
            case "ringRadius":
                if case .number(let number) = value { ringRadius = number }
            case "caption":
                if case .text(let text) = value { caption = text }
            case "captionSize":
                if case .number(let number) = value { captionSize = number }
            case "backdrop":
                if case .flag(let flag) = value { backdrop = flag }
            default:
                break
            }
        }
    }
}

public func resolveStyles(items: [Item], global: [String: StyleValue], group: [String: StyleValue]?, satellite: Bool, appearance: Appearance) -> [ButtonStyle] {
    items.map { item in
        var style = ButtonStyle.base(count: items.count, satellite: satellite, appearance: appearance)
        style.apply(global)
        if let group { style.apply(group) }
        style.apply(item.style)
        return style
    }
}

// The ring opens at the pointer, moved in from the screen's edges just far enough to show every button.
// Near a corner the pointer could not otherwise leave the dead zone toward a button past the edge.
public func ringCentre(pointer: Vec, screen: Vec, items: [Item], style: [String: StyleValue], appearance: Appearance) -> Vec {
    let styles = resolveStyles(items: items, global: style, group: nil, satellite: false, appearance: appearance)
    let reach = styles.map { style -> Double in
        let caption = style.caption == "none" ? 0 : 16 + max(style.captionSize, 11) * 2
        return style.ringRadius + style.size * appearance.highlightScale / 2 + style.glowSize + caption
    }.max() ?? 0
    func inside(_ value: Double, _ length: Double) -> Double {
        length < reach * 2 ? length / 2 : min(max(value, reach), length - reach)
    }
    return Vec(inside(pointer.x, screen.x), inside(pointer.y, screen.y))
}

public struct Appearance: Equatable {
    public var scale: Double
    public var atCursor: Bool
    public var deadZone: Double
    public var sliceGap: Double
    public var enlargeSelected: Bool
    public var labels: String
    public var restMs: Double
    public var closeGraceMs: Double

    public init(scale: Double = 1, atCursor: Bool = true, deadZone: Double = 40, sliceGap: Double = 0, enlargeSelected: Bool = true, labels: String = "none", restMs: Double = 250, closeGraceMs: Double = 150) {
        self.scale = scale
        self.atCursor = atCursor
        self.deadZone = deadZone
        self.sliceGap = sliceGap
        self.enlargeSelected = enlargeSelected
        self.labels = labels
        self.restMs = restMs
        self.closeGraceMs = closeGraceMs
    }

    public var deadZonePx: Double { max(0, deadZone) * scale }
    public var outerMargin: Double { 70 * scale }
    public var highlightScale: Double { enlargeSelected ? 1.1 : 1 }

    public func ringRadius(count: Int, satellite: Bool) -> Double {
        let n = max(count, 1)
        let base = max(110 * scale, Double(n) * 54 * scale / (2 * .pi))
        return (satellite ? base * 0.8 : base).rounded()
    }

    public func clamped() -> Appearance {
        var copy = self
        copy.scale = min(2, max(0.5, scale))
        copy.deadZone = max(0, deadZone)
        copy.sliceGap = min(0.5, max(0, sliceGap))
        if labels != "none" && labels != "selected" && labels != "all" {
            copy.labels = "none"
        }
        copy.restMs = max(0, restMs)
        copy.closeGraceMs = max(0, closeGraceMs)
        return copy
    }
}

public struct MenuFile: Equatable {
    public var items: [Item]
    public var style: [String: StyleValue]
    public var warnings: [String]

    public init(items: [Item], style: [String: StyleValue], warnings: [String]) {
        self.items = items
        self.style = style
        self.warnings = warnings
    }
}

private let styleKeys: Set<String> = [
    "shape", "cornerRadius", "size", "glowColor", "glowSize", "ringRadius", "caption", "captionSize", "backdrop",
]

public func parseMenu(_ data: Data) -> MenuFile {
    guard let json = try? JSONSerialization.jsonObject(with: data) else {
        return MenuFile(items: [], style: [:], warnings: ["appring: unreadable config"])
    }
    var styleRaw: Any = [String: Any]()
    var itemsRaw: Any = [Any]()
    if let array = json as? [Any] {
        itemsRaw = array
    } else if let object = json as? [String: Any] {
        styleRaw = object["style"] ?? [String: Any]()
        itemsRaw = object["items"] ?? [Any]()
    }
    var warnings: [String] = []
    let (style, styleWarnings) = styleValues(styleRaw, context: "global style")
    warnings.append(contentsOf: styleWarnings)
    let items = parseItems(itemsRaw, depth: 0, context: "", warnings: &warnings)
    return MenuFile(items: items, style: style, warnings: warnings)
}

public func loadAppearance(data: Data?, env: [String: String], defaultLabels: String = "none") -> Appearance {
    var appearance = Appearance(labels: defaultLabels)
    if let rest = env["APPRING_REST_MS"] ?? env["RING_APP_REST_MS"], let value = Double(rest) {
        appearance.restMs = value
    }
    if let close = env["APPRING_CLOSE_MS"] ?? env["RING_APP_CLOSE_MS"], let value = Double(close) {
        appearance.closeGraceMs = value
    }
    if let data, let json = try? JSONSerialization.jsonObject(with: data), let object = json as? [String: Any] {
        if let value = number(object["scale"]) { appearance.scale = value }
        if let value = object["atCursor"] as? Bool { appearance.atCursor = value }
        if let value = number(object["deadZone"]) { appearance.deadZone = value }
        if let value = number(object["sliceGap"]) { appearance.sliceGap = value }
        if let value = object["enlargeSelected"] as? Bool { appearance.enlargeSelected = value }
        if let value = object["labels"] as? String { appearance.labels = value }
    }
    return appearance.clamped()
}

// The menu name goes into the file name. No slash and no "..": open would read an arbitrary path.
public func menuFileName(_ name: String) -> String? {
    if name.isEmpty { return "menu.json" }
    if name.contains("/") || name.contains("\\") || name.contains("..") { return nil }
    if name.unicodeScalars.contains(where: { $0.value < 32 }) { return nil }
    return "menu-\(name).json"
}

public func resolveConfigDirectory(env: [String: String], home: String, exists: (String) -> Bool) -> (path: String, legacy: Bool) {
    if let override = env["APPRING_CONFIG_DIR"] ?? env["RING_APP_CONFIG_DIR"], !override.isEmpty {
        return (override, false)
    }
    let base = (env["XDG_CONFIG_HOME"]?.isEmpty == false ? env["XDG_CONFIG_HOME"]! : home + "/.config")
    let newer = base + "/appring"
    let older = base + "/ring-app"
    if !exists(newer) && exists(older) {
        return (older, true)
    }
    return (newer, false)
}

public func resolveExecutable(argv0: String, path: String, isExecutable: (String) -> Bool) -> String? {
    if argv0.isEmpty { return nil }
    if argv0.contains("/") {
        return isExecutable(argv0) ? argv0 : nil
    }
    for directory in path.split(separator: ":") where !directory.isEmpty {
        let candidate = "\(directory)/\(argv0)"
        if isExecutable(candidate) { return candidate }
    }
    return nil
}

// A process started from the Dock has a short PATH, without Homebrew. Commands from menu.json are looked up there too.
public func commandSearchPath(_ current: String?) -> String {
    var parts = (current ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
    for extra in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !parts.contains(extra) {
        parts.append(extra)
    }
    return parts.joined(separator: ":")
}

private func parseItems(_ raw: Any, depth: Int, context: String, warnings: inout [String]) -> [Item] {
    guard let array = raw as? [Any] else { return [] }
    var items: [Item] = []
    for entry in array {
        guard let object = entry as? [String: Any], let label = object["label"] as? String else { continue }
        var item = Item(label: label, icon: object["icon"] as? String ?? "", run: stringList(object["run"]))
        if let styleRaw = object["style"] {
            let (style, styleWarnings) = styleValues(styleRaw, context: "item \"\(label)\"\(context)")
            item.style = style
            warnings.append(contentsOf: styleWarnings)
        }
        if depth == 0, let children = object["items"] {
            item.items = parseItems(children, depth: 1, context: " (child of \"\(label)\")", warnings: &warnings)
        }
        items.append(item)
    }
    return items
}

private func styleValues(_ raw: Any, context: String) -> ([String: StyleValue], [String]) {
    guard let object = raw as? [String: Any] else { return ([:], []) }
    var values: [String: StyleValue] = [:]
    var warnings: [String] = []
    for key in object.keys.sorted() {
        guard styleKeys.contains(key) else {
            warnings.append("appring: unknown style key \"\(key)\" (\(context)), ignored")
            continue
        }
        if let value = styleValue(object[key]) {
            values[key] = value
        }
    }
    return (values, warnings)
}

private func styleValue(_ raw: Any?) -> StyleValue? {
    guard let raw else { return nil }
    if let text = raw as? String { return .text(text) }
    // `as? Bool` also accepts the numbers 0 and 1. A JSON bool is a CFBoolean, so check for it before a number.
    if let flag = boolean(raw) { return .flag(flag) }
    if let number = number(raw) { return .number(number) }
    return nil
}

private func boolean(_ raw: Any) -> Bool? {
    guard let number = raw as? NSNumber else { return raw as? Bool }
    guard CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
}

private func number(_ raw: Any?) -> Double? {
    if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
    switch raw {
    case let value as Double: return value
    case let value as Int: return Double(value)
    case let value as NSNumber: return value.doubleValue
    default: return nil
    }
}

private func stringList(_ raw: Any?) -> [String] {
    guard let array = raw as? [Any] else { return [] }
    return array.compactMap { entry in
        if let text = entry as? String { return text }
        if let number = entry as? NSNumber { return number.stringValue }
        return nil
    }
}

public struct Satellite: Equatable {
    public var parentIndex: Int
    public var items: [Item]
    public var styles: [ButtonStyle]
    public var centreX: Double
    public var centreY: Double
    public var highlighted: Int
    public var deadZone: Bool
    public var pointerAngle: Double
    public var buttonRadius: Double
    public var closeRadius: Double
    public var parentAngle: Double
    public var closeAngleThreshold: Double
}

public enum CommitEffect: Equatable {
    case ignored
    case closed
    case ran([String])
    case back
}

public struct Session: Equatable {
    public var open = false
    public var items: [Item] = []
    public var styles: [ButtonStyle] = []
    public var globalStyle: [String: StyleValue] = [:]
    public var highlighted = -1
    public var deadZone = true
    public var centreX = -1.0
    public var centreY = -1.0
    public var pointerX = 0.0
    public var pointerY = 0.0
    public var pointerAngle = 0.0
    public var satellite: Satellite?
    public var screenWidth = 0.0
    public var screenHeight = 0.0
    public var appearance = Appearance()
    // Counts the times the ring opened. A hold commits only the opening it started, not one that replaced it.
    public private(set) var opening = 0
    // now in pointer/advance/openMenu is in milliseconds. commit() needs lastNow, it has no clock of its own.
    private var lastNow: Double = 0
    private var pastOuterHandled = false
    private var groupDeadline: Double?
    private var satCloseDeadline: Double?

    public init() {}

    public mutating func openMenu(items: [Item], style: [String: StyleValue], centre: Vec, pointer: Vec, screen: Vec, appearance: Appearance, now: Double) {
        open = true
        opening += 1
        self.items = items
        globalStyle = style
        self.appearance = appearance
        styles = resolveStyles(items: items, global: style, group: nil, satellite: false, appearance: appearance)
        satellite = nil
        highlighted = -1
        deadZone = true
        pastOuterHandled = false
        groupDeadline = nil
        satCloseDeadline = nil
        centreX = centre.x
        centreY = centre.y
        pointerX = pointer.x
        pointerY = pointer.y
        screenWidth = screen.x
        screenHeight = screen.y
        lastNow = now
        recompute(now: now)
    }

    public func isOpen(since opening: Int?) -> Bool {
        open && opening == self.opening
    }

    public mutating func pointer(_ point: Vec, now: Double) {
        guard open else { return }
        pointerX = point.x
        pointerY = point.y
        lastNow = now
        recompute(now: now)
    }

    public mutating func advance(now: Double) {
        guard open else { return }
        lastNow = now
        recompute(now: now)
    }

    public mutating func commit() -> CommitEffect {
        guard open else { return .ignored }
        if satellite != nil, satCloseDeadline != nil {
            // Closing: the satellite keeps its selection only to draw the grace. Close it now and commit the main ring.
            satellite = nil
            satCloseDeadline = nil
            pastOuterHandled = false
            groupDeadline = nil
            recompute(now: lastNow)
        }
        if let satellite {
            if !satellite.deadZone && satellite.highlighted < 0 {
                cancel()
                return .closed
            }
            if satellite.deadZone {
                self.satellite = nil
                satCloseDeadline = nil
                pastOuterHandled = false
                groupDeadline = nil
                recompute(now: lastNow)
                return .back
            }
            guard satellite.items.indices.contains(satellite.highlighted) else {
                cancel()
                return .closed
            }
            let item = satellite.items[satellite.highlighted]
            let argv = item.run
            close()
            return argv.isEmpty ? .closed : .ran(argv)
        }
        if deadZone || highlighted < 0 || highlighted >= items.count {
            cancel()
            return .closed
        }
        let item = items[highlighted]
        if item.isGroup {
            openSatellite(highlighted)
            return .back
        }
        let argv = item.run
        close()
        return argv.isEmpty ? .closed : .ran(argv)
    }

    public mutating func cancel() {
        close()
    }

    private mutating func close() {
        open = false
        items = []
        styles = []
        satellite = nil
        highlighted = -1
        deadZone = true
        centreX = -1
        centreY = -1
        pastOuterHandled = false
        groupDeadline = nil
        satCloseDeadline = nil
    }

    private mutating func recompute(now: Double) {
        // Closing the satellite recomputes the main ring at once. A second pass is enough.
        if recomputeOnce(now: now) {
            _ = recomputeOnce(now: now)
        }
    }

    private mutating func recomputeOnce(now: Double) -> Bool {
        guard open, screenWidth > 0, screenHeight > 0 else { return false }
        let mdx = pointerX - centreX
        let mdy = pointerY - centreY
        let mdist = hypot(mdx, mdy)
        let mainDead = mdist < appearance.deadZonePx
        var mainIdx = -1
        var mainAngle = pointerAngle
        if !mainDead && !items.isEmpty {
            let slice = sliceOf(dx: mdx, dy: mdy, count: items.count, gap: appearance.sliceGap)
            mainIdx = slice.index
            mainAngle = slice.angle
        }

        if var satellite {
            let sdx = pointerX - satellite.centreX
            let sdy = pointerY - satellite.centreY
            let sdist = hypot(sdx, sdy)
            let nearButton = sdist < satellite.buttonRadius
            let towardCentre = mdist < satellite.closeRadius
            var angleDiff = abs(mainAngle - satellite.parentAngle)
            if angleDiff > 180 { angleDiff = 360 - angleDiff }
            // As in QML: compare the angle even when the pointer is in the dead zone and no index is selected.
            let differentItem = angleDiff > satellite.closeAngleThreshold
            let shouldClose = towardCentre || differentItem
            if shouldClose {
                if satCloseDeadline == nil {
                    satCloseDeadline = now + appearance.closeGraceMs
                }
                if let deadline = satCloseDeadline, now >= deadline {
                    self.satellite = nil
                    satCloseDeadline = nil
                    pastOuterHandled = false
                    groupDeadline = nil
                    return true
                }
                pointerAngle = mainAngle
                self.satellite = satellite
                return false
            }
            satCloseDeadline = nil
            var idx = -1
            var angle = satellite.pointerAngle
            if !nearButton && !satellite.items.isEmpty {
                let slice = sliceOf(dx: sdx, dy: sdy, count: satellite.items.count, gap: appearance.sliceGap)
                idx = slice.index
                angle = slice.angle
            }
            satellite.highlighted = idx
            satellite.deadZone = nearButton
            satellite.pointerAngle = angle
            self.satellite = satellite
            highlighted = satellite.parentIndex
            deadZone = false
            pointerAngle = mainAngle
            return false
        }

        deadZone = mainDead
        pointerAngle = mainAngle
        if mainDead || items.isEmpty {
            if highlighted != -1 {
                highlighted = -1
                groupDeadline = nil
            }
            return false
        }
        if mainIdx != highlighted {
            highlighted = mainIdx
            pastOuterHandled = false
            if mainIdx >= 0, items[mainIdx].isGroup {
                groupDeadline = now + appearance.restMs
            } else {
                groupDeadline = nil
            }
        }
        guard mainIdx >= 0, mainIdx < items.count else { return false }
        let radius = styles[mainIdx].ringRadius
        if items[mainIdx].isGroup && mdist > radius + appearance.outerMargin && !pastOuterHandled {
            pastOuterHandled = true
            openSatellite(mainIdx)
            return false
        }
        if let deadline = groupDeadline, now >= deadline, highlighted >= 0, items[highlighted].isGroup, satellite == nil, !pastOuterHandled {
            pastOuterHandled = true
            groupDeadline = nil
            openSatellite(highlighted)
        }
        return false
    }

    private mutating func openSatellite(_ index: Int) {
        guard items.indices.contains(index), items[index].isGroup else { return }
        let parent = items[index]
        let parentStyle = styles[index]
        let childStyles = resolveStyles(items: parent.items, global: globalStyle, group: parent.style, satellite: true, appearance: appearance)
        let pos = buttonCenter(index: index, count: items.count, centre: Vec(centreX, centreY), radius: parentStyle.ringRadius)
        let reach = childStyles.map { $0.ringRadius + $0.size }.max() ?? 0
        let margin = appearance.deadZonePx + reach + 20
        let sliceWidth = items.isEmpty ? 360 : 360 / Double(items.count)
        satellite = Satellite(
            parentIndex: index,
            items: parent.items,
            styles: childStyles,
            centreX: min(max(pos.x, margin), screenWidth - margin),
            centreY: min(max(pos.y, margin), screenHeight - margin),
            highlighted: -1,
            deadZone: true,
            pointerAngle: 0,
            buttonRadius: parentStyle.size * 1.2,
            closeRadius: parentStyle.ringRadius * 0.6,
            parentAngle: Double(index) * sliceWidth,
            closeAngleThreshold: sliceWidth / 2 + 15
        )
        highlighted = index
        deadZone = false
        groupDeadline = nil
        satCloseDeadline = nil
    }
}
