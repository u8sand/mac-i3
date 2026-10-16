// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mac-i3 contributors

import AppKit
import ApplicationServices

/// macOS stacks windows by app: the frontmost app's windows sit above every other app's, and
/// `AXRaise` only reorders within an app. To keep a floating window above a focused tiled window of
/// another app we briefly make the float's app frontmost, then hand keyboard focus back to the tiled
/// window without raising it. Uses private SkyLight / HIServices calls (the same ones other macOS
/// window managers use); everything is looked up at runtime so a missing symbol just disables it.
enum FrontOrder {
    private typealias SetFront = @convention(c) (UnsafeRawPointer, UInt32, UInt32) -> Int32
    private typealias PostEvent = @convention(c) (UnsafeRawPointer, UnsafePointer<UInt8>) -> Int32
    private typealias GetPSN = @convention(c) (UnsafeMutableRawPointer) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func sym<T>(_ name: String, _: T.Type) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    private static let setFront = sym("_SLPSSetFrontProcessWithOptions", SetFront.self)
    private static let postEvent = sym("SLPSPostEventRecordTo", PostEvent.self)
    private static let getFront = sym("_SLPSGetFrontProcess", GetPSN.self)

    static var available: Bool { setFront != nil && postEvent != nil && getFront != nil }

    private static let allWindows: UInt32 = 0x100, _unused: UInt32 = 0

    private typealias ForPID = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    private static let forPID: ForPID? = {
        guard let h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let p = dlsym(h, "GetProcessForPID") else { return nil }
        return unsafeBitCast(p, to: ForPID.self)
    }()

    private static func psn(of pid: pid_t) -> [UInt32]? {
        guard let forPID else { return nil }
        var p = [UInt32](repeating: 0, count: 2)
        return p.withUnsafeMutableBytes { forPID(pid, $0.baseAddress!) } == 0 ? p : nil
    }

    /// Make `pid`'s window `wid` the frontmost, raised window.
    static func bringToFront(pid: pid_t, window wid: UInt32) {
        guard let setFront, let psn = psn(of: pid) else { return }
        _ = psn.withUnsafeBytes { setFront($0.baseAddress!, wid, allWindows) }
    }

    /// Make `pid` frontmost and `wid` its key window without raising it, as yabai does: tell the
    /// currently front window (`from`) it lost focus, mark `pid` as the user-activated process, then post the
    /// "became key" event pair to the target window.
    static func focusWithoutRaise(pid: pid_t, window wid: UInt32, from front: UInt32) {
        guard let postEvent, let getFront, let target = psn(of: pid) else { return }
        var frontPSN = [UInt32](repeating: 0, count: 2)
        _ = frontPSN.withUnsafeMutableBytes { getFront($0.baseAddress!) }
        func record(_ kind: UInt8, _ wid: UInt32, focus: UInt8? = nil) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: 0xf8)
            b[0x04] = 0xf8; b[0x08] = kind
            if let focus { b[0x8a] = focus } else { b[0x3a] = 0x10 }
            withUnsafeBytes(of: wid) { for i in 0..<4 { b[0x3c + i] = $0[i] } }
            for i in 0..<0x10 { b[0x20 + i] = 0xff }
            return b
        }
                let defocus = record(0x0d, front, focus: 0x02)
        _ = frontPSN.withUnsafeBytes { postEvent($0.baseAddress!, defocus) }
        let focus = record(0x0d, wid, focus: 0x01)
        _ = target.withUnsafeBytes { postEvent($0.baseAddress!, focus) }
        for kind: UInt8 in [0x01, 0x02] {
            let e = record(kind, wid)
            _ = target.withUnsafeBytes { postEvent($0.baseAddress!, e) }
        }
    }

    /// Tell `pid` that `wid` is its active, key window again (after `focusWithoutRaise` told it otherwise).
    static func reactivate(pid: pid_t, window wid: UInt32) {
        guard let postEvent, let target = psn(of: pid) else { return }
        func record(_ kind: UInt8, focus: UInt8? = nil) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: 0xf8)
            b[0x04] = 0xf8; b[0x08] = kind
            if let focus { b[0x8a] = focus } else { b[0x3a] = 0x10 }
            withUnsafeBytes(of: wid) { for i in 0..<4 { b[0x3c + i] = $0[i] } }
            for i in 0..<0x10 { b[0x20 + i] = 0xff }
            return b
        }
        for e in [record(0x0d, focus: 0x01), record(0x01), record(0x02)] {
            _ = target.withUnsafeBytes { postEvent($0.baseAddress!, e) }
        }
    }
}
