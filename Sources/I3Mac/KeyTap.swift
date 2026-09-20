import CoreGraphics
import Foundation
import I3Config

/// Global keyboard hook. Matching chords are swallowed so the focused app never sees them.
final class KeyTap {
    /// Return true to swallow the event. Must be fast: it runs inside the event tap callback.
    var handler: ((_ keyCode: UInt16, _ mods: Modifiers, _ isDown: Bool) -> Bool)?
    fileprivate var tap: CFMachPort?
    private var source: CFRunLoopSource?
    fileprivate var swallowedDown = Set<UInt16>()

    func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let ref = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: keyTapCallback, userInfo: ref) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
    }

    static func modifiers(from flags: CGEventFlags) -> Modifiers {
        var m = Modifiers()
        if flags.contains(.maskShift) { m.insert(.shift) }
        if flags.contains(.maskControl) { m.insert(.control) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskCommand) { m.insert(.command) }
        return m
    }
}

private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
    let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let mods = KeyTap.modifiers(from: event.flags)
    if type == .keyUp {
        if me.swallowedDown.remove(code) != nil { return nil }
        return Unmanaged.passUnretained(event)
    }
    if me.handler?(code, mods, true) == true {
        me.swallowedDown.insert(code)
        return nil
    }
    return Unmanaged.passUnretained(event)
}

/// Posts synthetic key presses (used by `mac-i3 inject` and the integration tests).
public enum KeyInjector {
    public static func press(_ chord: String) -> Bool {
        guard let (mods, code) = ConfigParser.parseChord(chord) else { return false }
        var flags = CGEventFlags()
        if mods.contains(.shift) { flags.insert(.maskShift) }
        if mods.contains(.control) { flags.insert(.maskControl) }
        if mods.contains(.option) { flags.insert(.maskAlternate) }
        if mods.contains(.command) { flags.insert(.maskCommand) }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
        return true
    }
}
