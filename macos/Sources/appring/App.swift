import AppKit
import AppringCore
import ApplicationServices

@main
enum Main {
    static func main() {
        switch parseCommand(CommandLine.arguments) {
        case .help(let ok):
            fputs(usage, ok ? stdout : stderr)
            exit(ok ? 0 : 2)
        case .version:
            print("appring 0.1.0")
            exit(0)
        case .preview(let directory):
            _ = NSApplication.shared
            Preview.write(into: directory)
            exit(0)
        case .run, .open, .commit, .cancel, .toggle, .settings, .stop:
            let app = NSApplication.shared
            let delegate = AppDelegate(command: parseCommand(CommandLine.arguments))
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}

enum Launch: Equatable {
    case run
    case open(String)
    case commit
    case cancel
    case toggle(String)
    case settings
    case stop
    case help(Bool)
    case version
    case preview(String)
}

func parseCommand(_ arguments: [String]) -> Launch {
    let args = Array(arguments.dropFirst())
    guard let first = args.first else { return .run }
    switch first {
    case "run": return .run
    case "open": return .open(args.count > 1 ? args[1] : "")
    case "commit": return .commit
    case "cancel": return .cancel
    case "toggle": return .toggle(args.count > 1 ? args[1] : "")
    case "settings": return .settings
    case "stop": return .stop
    case "version", "--version": return .version
    case "help", "-h", "--help": return .help(true)
    case "--preview": return .preview(args.count > 1 ? args[1] : "/tmp/appring-preview")
    default: return .help(false)
    }
}

private let usage = """
appring 0.1.0: a radial menu for the desktop. Hold a key, point, release to run.

usage: appring [COMMAND]

  run           start it, hidden until opened (the default)
  open [NAME]   show the menu: menu.json, or menu-NAME.json
  commit        run the highlighted item and close
  cancel        close without running anything
  toggle [NAME] open, or close if open
  settings      show the menu file
  stop          stop it
  version       print the version

macOS: a menu-bar app. Hold Right Option (change it from the menu bar), point, release.
The hold key needs Accessibility permission. Menus: ${XDG_CONFIG_HOME:-~/.config}/appring/.

"""

final class AppDelegate: NSObject, NSApplicationDelegate, RingActions, NSMenuDelegate {
    private let command: Launch
    private let server = CommandServer()
    private var session = Session()
    private var panel: RingPanel?
    private var ringView: RingView?
    private var timer: Timer?
    private var statusItem: NSStatusItem?
    private var hotkey: HotkeyMonitor?
    // The opening this hold started; its release commits only that one.
    private var holdOpening: Int?
    private var warnedLegacy = false
    private var icons: [String: NSImage] = [:]

    init(command: Launch) {
        self.command = command
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch command {
        case .commit:
            finish(CommandSocket.send("commit"))
            return
        case .cancel:
            finish(CommandSocket.send("cancel"))
            return
        case .stop:
            _ = CommandSocket.send("stop")
            finish(true)
            return
        case .settings:
            if CommandSocket.send("settings") { finish(true); return }
            revealMenu()
            finish(true)
            return
        case .open(let name):
            if CommandSocket.sendReady(name.isEmpty ? "open" : "open \(name)") { finish(true); return }
        case .toggle(let name):
            if CommandSocket.sendReady(name.isEmpty ? "toggle" : "toggle \(name)") { finish(true); return }
        case .run:
            if CommandSocket.sendReady("ping") { finish(true); return }
        default:
            break
        }
        guard server.start() else {
            let line: String
            switch command {
            case .open(let name): line = name.isEmpty ? "open" : "open \(name)"
            case .toggle(let name): line = name.isEmpty ? "toggle" : "toggle \(name)"
            default: line = "ping"
            }
            if CommandSocket.send(line) { finish(true); return }
            fputs("appring: already running, or the command socket could not be created\n", stderr)
            finish(false)
            return
        }
        server.onLine = { [weak self] line in self?.handle(line) }
        installStatusItem()
        installHotkey()
        switch command {
        case .open(let name): openRing(name: name)
        case .toggle(let name): openRing(name: name)
        default: break
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        hotkey?.stop()
        server.stop()
    }

    func ringCommit(at screenPoint: NSPoint) { performCommit(at: screenPoint) }
    func ringCancel() { hideRing() }

    private func handle(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let name = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "ping", "run": break
        case "open": openRing(name: name)
        case "toggle":
            if session.open { hideRing() } else { openRing(name: name) }
        case "commit": performCommit()
        case "cancel": hideRing()
        case "settings": revealMenu()
        case "stop": NSApp.terminate(nil)
        default: break
        }
    }

    private func finish(_ sent: Bool) {
        if !sent {
            fputs("appring: not running\n", stderr)
            NSApp.terminate(nil)
            exit(1)
        }
        NSApp.terminate(nil)
        exit(0)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = statusImage()
        item.button?.toolTip = "appring"
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Open", action: #selector(openFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Edit menu…", action: #selector(editMenu), keyEquivalent: "")
        let hold = NSMenuItem(title: "Hold key", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for key in HoldKey.allCases {
            let entry = NSMenuItem(title: key.title, action: #selector(chooseKey(_:)), keyEquivalent: "")
            entry.representedObject = key.rawValue
            entry.state = key == HoldKey.stored() ? .on : .off
            entry.target = self
            submenu.addItem(entry)
        }
        hold.submenu = submenu
        menu.addItem(hold)
        let access = NSMenuItem(title: "Accessibility", action: #selector(promptAccess), keyEquivalent: "")
        access.tag = 1
        access.target = self
        menu.addItem(access)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        for entry in menu.items where entry.action != nil && entry.target == nil {
            entry.target = self
        }
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        let trusted = AXIsProcessTrusted()
        menu.item(withTag: 1)?.title = trusted ? "Accessibility: on" : "Allow Accessibility…"
        // The Accessibility dialog doesn't wait for an answer. By the next time the menu opens, access may be there.
        if trusted, hotkey?.installed != true { installHotkey() }
        let current = HoldKey.stored()
        if let submenu = menu.item(withTitle: "Hold key")?.submenu {
            for entry in submenu.items {
                entry.state = (entry.representedObject as? String) == current.rawValue ? .on : .off
            }
        }
    }

    @objc private func openFromMenu() { openRing(name: "") }

    @objc private func editMenu() { revealMenu() }

    @objc private func chooseKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = HoldKey(rawValue: raw) else { return }
        UserDefaults.standard.set(key.rawValue, forKey: "holdKey")
        installHotkey()
    }

    @objc private func promptAccess() {
        promptForAccessibility()
        installHotkey()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func installHotkey() {
        hotkey?.stop()
        let monitor = HotkeyMonitor(
            key: HoldKey.stored(),
            isOpen: { [weak self] in self?.session.open ?? false },
            onDown: { [weak self] in
                guard let self, !self.session.open else { return }
                self.openRing(name: "")
                self.holdOpening = self.session.open ? self.session.opening : nil
            },
            onUp: { [weak self] in
                guard let self else { return }
                let opening = self.holdOpening
                self.holdOpening = nil
                guard self.session.isOpen(since: opening) else { return }
                self.performCommit()
            },
            onEscape: { [weak self] in self?.hideRing() }
        )
        if !monitor.start() {
            fputs("appring: no Accessibility permission, the hold key will not work. Use the menu bar item Allow Accessibility, or System Settings, Privacy & Security.\n", stderr)
        }
        hotkey = monitor
    }

    private func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func openRing(name: String) {
        let menu = loadMenu(name: name)
        for warning in menu.warnings {
            fputs(warning + "\n", stderr)
        }
        let appearance = loadAppearance(data: appearanceData(), env: ProcessInfo.processInfo.environment, defaultLabels: "selected")
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let panel = ensurePanel()
        panel.setFrame(screen.frame, display: false)
        ringView?.frame = NSRect(origin: .zero, size: panel.contentLayoutRect.size)
        var pointer = modelPoint(mouse, frame: panel.frame)
        let size = Vec(screen.frame.width, screen.frame.height)
        let centre = appearance.atCursor
            ? ringCentre(pointer: pointer, screen: size, items: menu.items, style: menu.style, appearance: appearance)
            : Vec(size.x / 2, size.y / 2)
        if appearance.atCursor && centre != pointer {
            // Moved in from an edge: the pointer goes with the ring, so it starts in the dead zone as usual.
            warpPointer(to: centre, frame: panel.frame)
            pointer = centre
        }
        session.openMenu(
            items: menu.items,
            style: menu.style,
            centre: centre,
            pointer: pointer,
            screen: size,
            appearance: appearance,
            now: nowMs()
        )
        ringView?.session = session
        ringView?.needsDisplay = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = appearance.scale == 0 ? 0 : 0.16
            panel.animator().alphaValue = 1
        }
        startTimer()
    }

    private func performCommit(at screenPoint: NSPoint = NSEvent.mouseLocation) {
        // A click can come before the next tick. Take its point now, or the previous sector would run.
        if session.open, let panel {
            session.pointer(modelPoint(screenPoint, frame: panel.frame), now: nowMs())
        }
        let effect = session.commit()
        ringView?.session = session
        ringView?.needsDisplay = true
        switch effect {
        case .ran(let argv):
            hideRing()
            run(argv)
        case .closed:
            hideRing()
        case .ignored, .back:
            break
        }
    }

    private func hideRing() {
        session.cancel()
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        ringView?.session = session
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard session.open, let panel else { return }
        session.pointer(modelPoint(NSEvent.mouseLocation, frame: panel.frame), now: nowMs())
        ringView?.session = session
        ringView?.needsDisplay = true
    }

    private func ensurePanel() -> RingPanel {
        if let panel { return panel }
        let panel = RingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        let view = RingView(frame: .zero)
        view.actions = self
        view.icon = { [weak self] item in self?.icon(for: item) }
        panel.contentView = view
        self.panel = panel
        ringView = view
        return panel
    }

    private func modelPoint(_ screenPoint: NSPoint, frame: NSRect) -> Vec {
        let yUp = screenPoint.y - frame.origin.y
        return Vec(screenPoint.x - frame.origin.x, frame.height - yUp)
    }

    // CoreGraphics counts from the top left of the main screen, AppKit from its bottom left.
    private func warpPointer(to point: Vec, frame: NSRect) {
        let mainHeight = NSScreen.screens.first?.frame.height ?? frame.height
        let x = frame.origin.x + point.x
        let y = mainHeight - (frame.maxY - point.y)
        CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
        // Without this the pointer stays still for a quarter of a second after the move.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func nowMs() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    private func paths() -> (path: String, legacy: Bool) {
        let home = NSHomeDirectory()
        return resolveConfigDirectory(env: ProcessInfo.processInfo.environment, home: home, exists: { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        })
    }

    private func loadMenu(name: String) -> MenuFile {
        guard let file = menuFileName(name) else {
            return MenuFile(items: [], style: [:], warnings: ["appring: bad menu name"])
        }
        let (directory, legacy) = paths()
        if legacy && !warnedLegacy {
            warnedLegacy = true
            let home = NSHomeDirectory()
            let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
            fputs("appring: reading the old config folder \(directory); move it to \(base)/appring\n", stderr)
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(file)
        if let data = try? Data(contentsOf: url) {
            return parseMenu(data)
        }
        if name.isEmpty, let data = defaultMenuData() {
            return parseMenu(data)
        }
        return MenuFile(items: [], style: [:], warnings: [])
    }

    private func appearanceData() -> Data? {
        let (directory, _) = paths()
        return try? Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("appearance.json"))
    }

    private func defaultMenuData() -> Data? {
        if let url = Bundle.main.url(forResource: "default", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        if let url = Bundle.module.url(forResource: "default", withExtension: "json") {
            return try? Data(contentsOf: url)
        }
        return nil
    }

    private func revealMenu() {
        let (directory, _) = paths()
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let menu = folder.appendingPathComponent("menu.json")
        if !FileManager.default.fileExists(atPath: menu.path), let data = defaultMenuData() {
            try? data.write(to: menu)
        }
        NSWorkspace.shared.open(menu)
    }

    private func run(_ argv: [String]) {
        guard let argv0 = argv.first, !argv0.isEmpty else { return }
        let path = commandSearchPath(ProcessInfo.processInfo.environment["PATH"])
        guard let executable = resolveExecutable(argv0: argv0, path: path, isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            fputs("appring: command not found: \(argv0)\n", stderr)
            NSSound.beep()
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            fputs("appring: could not run \(executable): \(error)\n", stderr)
            NSSound.beep()
        }
    }

    private func icon(for item: Item) -> NSImage? {
        let key = item.run.joined(separator: "\u{0}") + "\u{0}" + item.icon
        if let cached = icons[key] { return cached }
        let image = lookupIcon(item)
        if let image { icons[key] = image }
        return image
    }

    private func lookupIcon(_ item: Item) -> NSImage? {
        if let index = item.run.firstIndex(of: "-a"), item.run.index(after: index) < item.run.endIndex {
            let name = item.run[item.run.index(after: index)]
            if let url = applicationURL(named: name) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        if let first = item.run.first, first.hasSuffix(".app"), FileManager.default.fileExists(atPath: first) {
            return NSWorkspace.shared.icon(forFile: first)
        }
        return nil
    }

    private func applicationURL(named name: String) -> URL? {
        let roots = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
            "/System/Library/CoreServices",
        ]
        for root in roots {
            let url = URL(fileURLWithPath: root).appendingPathComponent(name + ".app")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private func statusImage() -> NSImage {
        if let url = Bundle.main.url(forResource: "appring", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.labelColor.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 1.5, y: 1.5, width: 15, height: 15))
        ring.lineWidth = 1.4
        ring.stroke()
        NSColor.labelColor.setFill()
        for point in [NSPoint(x: 8, y: 13), NSPoint(x: 13, y: 8), NSPoint(x: 8, y: 3), NSPoint(x: 3, y: 8)] {
            NSBezierPath(ovalIn: NSRect(x: point.x - 1.3, y: point.y - 1.3, width: 2.6, height: 2.6)).fill()
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

final class RingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum Preview {
    static func write(into directory: String) {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let menu = parseMenu(defaultMenuData() ?? Data())
        var main = Session()
        let appearance = Appearance(labels: "selected")
        main.openMenu(items: menu.items, style: menu.style, centre: Vec(450, 350), pointer: Vec(450, 200), screen: Vec(900, 700), appearance: appearance, now: 0)
        write(main, to: folder.appendingPathComponent("main.png"))
        var satellite = main
        satellite.pointer(Vec(250, 350), now: 0)
        write(satellite, to: folder.appendingPathComponent("satellite.png"))
    }

    private static func write(_ session: Session, to url: URL) {
        let size = NSSize(width: 900, height: 700)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1800,
            pixelsHigh: 1400,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 0.07, green: 0.07, blue: 0.1, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        RingDrawer.draw(session: session, icon: { item in
            guard let index = item.run.firstIndex(of: "-a"), item.run.index(after: index) < item.run.endIndex else { return nil }
            let name = item.run[item.run.index(after: index)]
            let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/System/Library/CoreServices"]
            for root in roots {
                let path = root + "/" + name + ".app"
                if FileManager.default.fileExists(atPath: path) {
                    return NSWorkspace.shared.icon(forFile: path)
                }
            }
            return nil
        }, in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func defaultMenuData() -> Data? {
        if let url = Bundle.module.url(forResource: "default", withExtension: "json") {
            return try? Data(contentsOf: url)
        }
        return nil
    }
}
