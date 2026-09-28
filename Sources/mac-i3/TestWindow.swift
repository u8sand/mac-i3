// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mac-i3 contributors

import AppKit

/// `mac-i3 test-window <title>`: a plain window with a big label, used by the integration tests
/// (and handy for trying the WM without touching real apps). Exits when the window is closed.
/// SIGUSR1 hides the window without closing it and SIGUSR2 shows it again: the same window (and ID) drops
/// out of the app's window list and comes back, as every window does around a screen lock.
func runTestWindow(title: String) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let win = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 300),
                       styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    win.title = title
    win.isReleasedWhenClosed = false
    // Exit on a real close only (not `applicationShouldTerminateAfterLastWindowClosed`, which also fires
    // once a merely hidden window leaves the app with nothing on screen).
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { _ in exit(0) }
    let hue = CGFloat(abs(title.hashValue % 360)) / 360
    win.backgroundColor = NSColor(hue: hue, saturation: 0.35, brightness: 0.95, alpha: 1)
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 64, weight: .bold)
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    win.contentView?.addSubview(label)
    NSLayoutConstraint.activate([
        label.centerXAnchor.constraint(equalTo: win.contentView!.centerXAnchor),
        label.centerYAnchor.constraint(equalTo: win.contentView!.centerYAnchor),
    ])
    win.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    var sources: [DispatchSourceSignal] = []
    for (sig, show) in [(SIGUSR1, false), (SIGUSR2, true)] {
        signal(sig, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        s.setEventHandler { if show { win.orderFront(nil) } else { win.orderOut(nil) } }
        s.resume()
        sources.append(s)
    }
    app.run()
    withExtendedLifetime(sources) { exit(0) }
}
