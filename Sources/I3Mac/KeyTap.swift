// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mac-i3 contributors

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
///
/// A chord is sent the way a keyboard sends it: each modifier is pressed as a real modifier key event,
/// then the key, then the modifiers are released in reverse order. Merely stamping flags on the key
/// event leaves the system-wide modifier state stuck (Option/Shift never "released"), which turns every
/// later real mouse click into an Option-click that hides apps.
public enum KeyInjector {
    private static let modifierKeys: [(mod: Modifiers, code: CGKeyCode, flag: CGEventFlags)] = [
        (.control, 59, .maskControl), (.option, 58, .maskAlternate), (.shift, 56, .maskShift), (.command, 55, .maskCommand),
    ]

    private static func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, modifier: Bool, _ src: CGEventSource?) {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return }
        if modifier { e.type = .flagsChanged }
        e.flags = flags
        e.post(tap: .cghidEventTap)
        usleep(8_000)
    }

    public static func press(_ chord: String) -> Bool {
        guard let (mods, code) = ConfigParser.parseChord(chord) else { return false }
        let src = CGEventSource(stateID: .hidSystemState)
        let held = modifierKeys.filter { mods.contains($0.mod) }
        var flags = CGEventFlags()
        for m in held {
            flags.insert(m.flag)
            post(m.code, down: true, flags: flags, modifier: true, src)
        }
        post(CGKeyCode(code), down: true, flags: flags, modifier: false, src)
        usleep(12_000)
        post(CGKeyCode(code), down: false, flags: flags, modifier: false, src)
        for m in held.reversed() {
            flags.remove(m.flag)
            post(m.code, down: false, flags: flags, modifier: true, src)
        }
        return true
    }

    /// Modifier keys the system currently believes are held, as chord names.
    public static func heldModifiers() -> [String] {
        let f = CGEventSource.flagsState(.hidSystemState)
        var out: [String] = []
        if f.contains(.maskAlternate) { out.append("Option") }
        if f.contains(.maskShift) { out.append("Shift") }
        if f.contains(.maskControl) { out.append("Control") }
        if f.contains(.maskCommand) { out.append("Command") }
        return out
    }

    /// Recovery: tell the system every modifier key was released.
    public static func releaseModifiers() {
        let src = CGEventSource(stateID: .hidSystemState)
        for code: CGKeyCode in [54, 55, 56, 57, 58, 59, 60, 61, 62, 63] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else { continue }
            e.flags = []
            e.post(tap: .cghidEventTap)
            usleep(5_000)
        }
    }
}
