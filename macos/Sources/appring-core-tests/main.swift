import AppringCore
import Foundation

var failures = 0

func expect(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        fputs("FAIL \(message)\n", stderr)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    expect(actual == expected, "\(message): \(actual) != \(expected)")
}

func expectNear(_ actual: Double, _ expected: Double, _ message: String) {
    expect(abs(actual - expected) < 0.001, "\(message): \(actual) != \(expected)")
}

func opened(gap: Double = 0) -> Session {
    var session = Session()
    var appearance = Appearance()
    appearance.sliceGap = gap
    session.openMenu(
        items: [
            Item(label: "Tools", items: [
                Item(label: "Hello", run: ["say", "hi"]),
                Item(label: "Calc", run: ["open", "-a", "Calculator"]),
            ]),
            Item(label: "Terminal", run: ["open", "-a", "Terminal"]),
            Item(label: "Finder", run: ["open", "-a", "Finder"]),
            Item(label: "Safari", run: ["open", "-a", "Safari"]),
        ],
        style: [:],
        centre: Vec(400, 400),
        pointer: Vec(400, 400),
        screen: Vec(800, 800),
        appearance: appearance,
        now: 0
    )
    return session
}

expectEqual(sliceOf(dx: 0, dy: -10, count: 4, gap: 0).index, 0, "up")
expectEqual(sliceOf(dx: 10, dy: 0, count: 4, gap: 0).index, 1, "right")
expectEqual(sliceOf(dx: 0, dy: 10, count: 4, gap: 0).index, 2, "down")
expectEqual(sliceOf(dx: -10, dy: 0, count: 4, gap: 0).index, 3, "left")

expectEqual(sliceOf(dx: 100, dy: -100, count: 4, gap: 0).index, 1, "boundary")
expectEqual(sliceOf(dx: 100, dy: -100, count: 4, gap: 0.5).index, -1, "gap")

let top = buttonCenter(index: 0, count: 4, centre: Vec(10, 10), radius: 5)
expectNear(top.x, 10, "button x")
expectNear(top.y, 5, "button y")

var centre = opened()
expect(centre.deadZone, "opens in the dead zone")
expectEqual(centre.commit(), .closed, "centre commit")
expect(!centre.open, "centre commit closes")

var leaf = opened()
leaf.pointer(Vec(550, 400), now: 0)
expectEqual(leaf.highlighted, 1, "right slice")
expectEqual(leaf.commit(), .ran(["open", "-a", "Terminal"]), "leaf run")
expect(!leaf.open, "leaf closes")

var rest = opened()
rest.pointer(Vec(400, 250), now: 0)
expect(rest.satellite == nil, "group waits")
rest.advance(now: 249)
expect(rest.satellite == nil, "group still waits")
rest.advance(now: 250)
expectEqual(rest.satellite?.parentIndex ?? -1, 0, "group opens on rest")
expect(rest.open, "rest keeps the ring")

var outer = opened()
outer.pointer(Vec(400, 200), now: 0)
expectEqual(outer.satellite?.parentIndex ?? -1, 0, "group opens past the ring")

var child = opened()
child.pointer(Vec(400, 200), now: 0)
let childCentreY = child.satellite?.centreY ?? 0
child.pointer(Vec(400, childCentreY - 100), now: 10)
expectEqual(child.satellite?.highlighted ?? -2, 0, "satellite child")
expectEqual(child.commit(), .ran(["say", "hi"]), "satellite run")

var back = opened()
back.pointer(Vec(400, 200), now: 0)
let backCentre = Vec(back.satellite?.centreX ?? 0, back.satellite?.centreY ?? 0)
back.pointer(backCentre, now: 10)
expectEqual(back.commit(), .back, "satellite centre")
expect(back.satellite == nil, "back to main")
expect(back.open, "main stays open")

var gap = opened(gap: 0.5)
gap.pointer(Vec(500, 300), now: 0)
expect(!gap.deadZone, "gap is not the centre")
expectEqual(gap.highlighted, -1, "gap selects nothing")
expectEqual(gap.commit(), .closed, "gap commit")

var cancelled = opened()
cancelled.pointer(Vec(550, 400), now: 0)
cancelled.cancel()
expect(!cancelled.open, "cancel")

var grace = opened()
grace.pointer(Vec(400, 200), now: 0)
expect(grace.satellite != nil, "grace starts open")
grace.pointer(Vec(400, 350), now: 20)
expect(grace.satellite != nil, "grace holds")
grace.advance(now: 20 + 149)
expect(grace.satellite != nil, "grace not yet")
grace.advance(now: 20 + 150)
expect(grace.satellite == nil, "grace elapsed")
expect(grace.open, "main stays after grace")

var leaving = opened()
leaving.pointer(Vec(400, 200), now: 0)
let leavingCentreY = leaving.satellite?.centreY ?? 0
leaving.pointer(Vec(400, leavingCentreY - 100), now: 10)
expectEqual(leaving.satellite?.highlighted ?? -2, 0, "leaving: a child is selected")
leaving.pointer(Vec(400, 400), now: 20)
expect(leaving.satellite != nil, "leaving: the satellite is still drawn during the grace")
expectEqual(leaving.commit(), .closed, "a release at the centre during the grace runs nothing, not the previous child")
expect(!leaving.open, "leaving: the ring closes")

var turning = opened()
turning.pointer(Vec(400, 200), now: 0)
let turningCentreY = turning.satellite?.centreY ?? 0
turning.pointer(Vec(400, turningCentreY - 100), now: 10)
turning.pointer(Vec(600, 400), now: 20)
expect(turning.satellite != nil, "turning: the satellite is still drawn during the grace")
expectEqual(turning.commit(), .ran(["open", "-a", "Terminal"]), "a release on another item during the grace runs that item")

var held = opened()
let heldOpening: Int? = held.opening
expect(held.isOpen(since: heldOpening), "a hold commits the ring it opened")
expect(!held.isOpen(since: nil), "a hold that opened nothing commits nothing")
held.cancel()
held.openMenu(items: [Item(label: "A", run: ["a"])], style: [:], centre: Vec(400, 400), pointer: Vec(400, 400), screen: Vec(800, 800), appearance: Appearance(), now: 30)
expect(!held.isOpen(since: heldOpening), "a hold does not commit a ring opened after it was cancelled")
held.cancel()
expect(!held.isOpen(since: held.opening), "a closed ring is not committed")

let four = [Item(label: "N"), Item(label: "E"), Item(label: "S"), Item(label: "W")]
let screen = Vec(1440, 900)
let middle = ringCentre(pointer: Vec(700, 450), screen: screen, items: four, style: [:], appearance: Appearance())
expectEqual(middle, Vec(700, 450), "the ring opens at the pointer when it fits")
let corner = ringCentre(pointer: Vec(10, 10), screen: screen, items: four, style: [:], appearance: Appearance())
let topButton = buttonCenter(index: 0, count: 4, centre: corner, radius: Appearance().ringRadius(count: 4, satellite: false))
expect(topButton.y - 24 * 1.1 > 0, "near a corner the top button is on screen: \(topButton)")
let leftButton = buttonCenter(index: 3, count: 4, centre: corner, radius: Appearance().ringRadius(count: 4, satellite: false))
expect(leftButton.x - 24 * 1.1 > 0, "near a corner the left button is on screen: \(leftButton)")
let farCorner = ringCentre(pointer: Vec(1439, 899), screen: screen, items: four, style: [:], appearance: Appearance())
expect(farCorner.x < 1439 && farCorner.y < 899, "the far corner moves in too")
var cornered = Session()
cornered.openMenu(items: four.map { Item(label: $0.label, run: [$0.label]) }, style: [:], centre: corner, pointer: corner, screen: screen, appearance: Appearance(), now: 0)
cornered.pointer(Vec(corner.x, corner.y - 60), now: 10)
expectEqual(cornered.commit(), .ran(["N"]), "near a corner the top item can be picked")
let tiny = ringCentre(pointer: Vec(10, 10), screen: Vec(200, 100), items: four, style: [:], appearance: Appearance())
expectEqual(tiny, Vec(100, 50), "a screen smaller than the ring gets it in the middle")

let json = """
{"style":{"size":80,"backdrop":true,"nope":1},"items":[
  {"label":"A","run":["echo",1]},
  {"label":"G","items":[{"label":"C","items":[{"label":"too deep"}]}]},
  {"run":["x"]}
]}
""".data(using: .utf8)!
let menu = parseMenu(json)
expectEqual(menu.items.map(\.label), ["A", "G"], "labels")
expectEqual(menu.items[0].run, ["echo", "1"], "run strings")
expectEqual(menu.items[1].items.map(\.label), ["C"], "children")
expect(menu.items[1].items[0].items.isEmpty, "one level")
expect(menu.warnings.contains { $0.contains("nope") }, "unknown style")
var styled = Session()
styled.openMenu(items: menu.items, style: menu.style, centre: Vec(0, 0), pointer: Vec(0, 0), screen: Vec(800, 800), appearance: Appearance(), now: 0)
expectEqual(styled.styles[0].size, 80, "style size")
expect(styled.styles[0].backdrop, "style backdrop")

let zeroAndOne = """
{"style":{"glowSize":0,"cornerRadius":1,"backdrop":true},"items":[{"label":"A"}]}
""".data(using: .utf8)!
let zeroMenu = parseMenu(zeroAndOne)
var zeroSession = Session()
zeroSession.openMenu(items: zeroMenu.items, style: zeroMenu.style, centre: Vec(0, 0), pointer: Vec(0, 0), screen: Vec(800, 800), appearance: Appearance(), now: 0)
expectEqual(zeroSession.styles[0].glowSize, 0, "glowSize zero stays a number")
expectEqual(zeroSession.styles[0].cornerRadius, 1, "cornerRadius one stays a number")
expect(zeroSession.styles[0].backdrop, "json true stays a flag")

let legacy = resolveConfigDirectory(env: [:], home: "/Users/me", exists: { $0 == "/Users/me/.config/ring-app" })
expectEqual(legacy.path, "/Users/me/.config/ring-app", "legacy dir")
expect(legacy.legacy, "legacy flag")
let newer = resolveConfigDirectory(env: [:], home: "/Users/me", exists: { $0.hasSuffix("/appring") || $0.hasSuffix("/ring-app") })
expectEqual(newer.path, "/Users/me/.config/appring", "new dir wins")
expect(!newer.legacy, "not legacy")
let override = resolveConfigDirectory(env: ["APPRING_CONFIG_DIR": "/opt/cfg", "RING_APP_CONFIG_DIR": "/old"], home: "/Users/me", exists: { _ in true })
expectEqual(override.path, "/opt/cfg", "override")
let xdg = resolveConfigDirectory(env: ["XDG_CONFIG_HOME": "/xdg"], home: "/Users/me", exists: { _ in false })
expectEqual(xdg.path, "/xdg/appring", "xdg")
expectEqual(menuFileName(""), "menu.json", "default menu file")
expectEqual(menuFileName("tools"), "menu-tools.json", "named menu")
expect(menuFileName("../secret") == nil, "reject dotdot")
expect(menuFileName("a/b") == nil, "reject slash")

expectEqual(resolveExecutable(argv0: "open", path: "/usr/bin:/bin", isExecutable: { $0 == "/usr/bin/open" }), "/usr/bin/open", "path lookup")
expect(resolveExecutable(argv0: "missing", path: "/usr/bin", isExecutable: { _ in false }) == nil, "missing command")
expectEqual(resolveExecutable(argv0: "/bin/echo", path: "", isExecutable: { $0 == "/bin/echo" }), "/bin/echo", "absolute")
expect(commandSearchPath("/usr/bin").contains("/opt/homebrew/bin"), "homebrew on path")
expectEqual(commandSearchPath("/opt/homebrew/bin:/usr/bin").components(separatedBy: "/opt/homebrew/bin").count, 2, "homebrew once")

let appearance = loadAppearance(
    data: #"{"scale":9,"labels":"nope","deadZone":-4}"#.data(using: .utf8),
    env: ["RING_APP_REST_MS": "40", "APPRING_CLOSE_MS": "10"],
    defaultLabels: "selected"
)
expectEqual(appearance.scale, 2, "scale clamp")
expectEqual(appearance.labels, "none", "bad labels")
expectEqual(appearance.deadZone, 0, "dead zone clamp")
expectEqual(appearance.restMs, 40, "legacy rest env")
expectEqual(appearance.closeGraceMs, 10, "close env")
let defaults = loadAppearance(data: nil, env: [:], defaultLabels: "selected")
expectEqual(defaults.labels, "selected", "default labels")
expectEqual(defaults.ringRadius(count: 4, satellite: false), 110, "radius")
expectEqual(Appearance(scale: 2).ringRadius(count: 4, satellite: false), 220, "scaled radius")

if failures > 0 {
    fputs("\(failures) failed\n", stderr)
    exit(1)
}
print("ok")
