// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mac-i3 contributors

import AppKit
import I3Config
import ServiceManagement

/// Things that only matter when mac-i3 runs as a double-clicked `.app` (no terminal, permissions belong to
/// the app itself) rather than as a command-line tool.
public enum AppInfo {
    /// Running from inside a `.app` bundle.
    public static var isBundled: Bool { Bundle.main.bundlePath.hasSuffix(".app") && Bundle.main.bundleIdentifier != nil }

    public static var versionString: String {
        guard isBundled else { return "mac-i3 (development build)" }
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "mac-i3 \(v) (build \(b))"
    }

    /// Where the source code, releases and bug reports live (the GPL asks binary releases to say where the source is).
    public static let sourceURL = "https://github.com/u8sand/mac-i3"

    // MARK: - Files

    public static var configPath: String { NSString(string: "~/.config/mac-i3/config").expandingTildeInPath }
    public static var logPath: String { NSString(string: "~/Library/Logs/mac-i3.log").expandingTildeInPath }

    /// Launched from Finder there is no terminal to print to, so send stderr (config errors, warnings) to a log
    /// file. A terminal-launched run keeps its stderr, and the log is trimmed once it grows large.
    public static func redirectLogsIfBundled() {
        guard isBundled, isatty(2) == 0 else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: logPath))?[.size] as? Int, size > 1_000_000 {
            try? fm.removeItem(atPath: logPath + ".1")
            try? fm.moveItem(atPath: logPath, toPath: logPath + ".1")
        }
        freopen(logPath, "a", stderr)
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(stamp)] \(versionString) starting\n".utf8))
    }

    /// A line in the log (stderr) regardless of `-v`: permission events are what you need when something "does not work".
    public static func note(_ s: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(stamp)] \(s)\n".utf8))
    }

    /// Accessibility / Input Monitoring as macOS currently reports them for this process.
    public static var accessibilityAllowed: Bool { AXIsProcessTrusted() }
    public static var inputMonitoringAllowed: Bool { CGPreflightListenEventAccess() }

    /// Opens the config in the default text editor, first writing the built-in default if there is none yet.
    public static func editConfig() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configPath) {
            try? fm.createDirectory(atPath: (configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? DefaultConfig.text.write(toFile: configPath, atomically: true, encoding: .utf8)
        }
        run("/usr/bin/open", ["-t", configPath])
    }

    public static func openLog() {
        if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
        run("/usr/bin/open", [logPath])
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        do { try p.run(); return true } catch { return false }
    }

    // MARK: - Permissions

    public static let accessibilityPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    public static let inputMonitoringPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"

    public static func openSettings(_ pane: String) {
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }

    /// Registers this app in the Privacy lists (so it shows up there) and raises the system prompts.
    public static func requestPermissions() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        _ = CGRequestListenEventAccess()
    }

    /// A blocking alert. Returns the index of the pressed button (0 = the first).
    @discardableResult
    static func alert(_ title: String, _ text: String, buttons: [String]) -> Int {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .informational
        for b in buttons { a.addButton(withTitle: b) }
        return a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    // MARK: - Launch at login

    public static var loginItemEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns an error message on failure.
    public static func setLoginItem(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch { return error.localizedDescription }
    }

    public static func about() {
        NSApp.activate(ignoringOtherApps: true)
        let font = NSFont.systemFont(ofSize: 11)
        let credits = NSMutableAttributedString(
            string: "i3-style tiling window management for macOS.\nFree software under the GNU General Public License, version 3 or later.\nConfig: ~/.config/mac-i3/config\n",
            attributes: [.font: font])
        credits.append(NSAttributedString(string: sourceURL, attributes: [.font: font, .link: URL(string: sourceURL)!]))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
