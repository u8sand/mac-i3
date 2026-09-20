import AppKit

/// `mac-i3 test-window <title>`: a plain window with a big label, used by the integration tests
/// (and handy for trying the WM without touching real apps). Exits when the window is closed.
func runTestWindow(title: String) -> Never {
    final class Delegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = Delegate()
    app.delegate = delegate

    let win = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 300),
                       styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    win.title = title
    win.isReleasedWhenClosed = false
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
    app.run()
    exit(0)
}
