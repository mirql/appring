import CoreGraphics
import Foundation

enum HoldKey: String, CaseIterable {
    case rightOption
    case rightCommand
    case rightControl
    case f19
    case grave

    var title: String {
        switch self {
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        case .rightControl: return "Right Control"
        case .f19: return "F19"
        case .grave: return "Grave (`)"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 0x3D
        case .rightCommand: return 0x36
        case .rightControl: return 0x3E
        case .f19: return 0x50
        case .grave: return 0x32
        }
    }

    // The right key's own bit, not the shared maskAlternate: the left Option may be held together with it.
    var deviceMask: UInt64 {
        switch self {
        case .rightOption: return 0x40
        case .rightCommand: return 0x10
        case .rightControl: return 0x2000
        default: return 0
        }
    }

    var isModifier: Bool { deviceMask != 0 }

    static func stored() -> HoldKey {
        let raw = UserDefaults.standard.string(forKey: "holdKey") ?? ""
        return HoldKey(rawValue: raw) ?? .rightOption
    }
}

final class HotkeyMonitor {
    var key: HoldKey
    var isOpen: () -> Bool
    var onDown: () -> Void
    var onUp: () -> Void
    var onEscape: () -> Void

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var held = false
    private(set) var installed = false

    init(key: HoldKey, isOpen: @escaping () -> Bool, onDown: @escaping () -> Void, onUp: @escaping () -> Void, onEscape: @escaping () -> Void) {
        self.key = key
        self.isOpen = isOpen
        self.onDown = onDown
        self.onUp = onUp
        self.onEscape = onEscape
    }

    func start() -> Bool {
        stop()
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyTapCallback,
            userInfo: refcon
        ) else {
            installed = false
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.source = source
        installed = true
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        installed = false
        held = false
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if key.isModifier {
            if type == .flagsChanged && code == key.keyCode {
                let down = (event.flags.rawValue & key.deviceMask) != 0
                setHeld(down)
                return nil
            }
        } else if code == key.keyCode && (type == .keyDown || type == .keyUp) {
            if type == .keyDown {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    setHeld(true)
                }
            } else {
                setHeld(false)
            }
            return nil
        }
        // While the ring is open, ordinary keys don't go to the window under it: on Linux the overlay has exclusive focus.
        if isOpen() && type == .keyDown {
            if code == 53 { onEscape() }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func setHeld(_ down: Bool) {
        if down == held { return }
        held = down
        if down { onDown() } else { onUp() }
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
