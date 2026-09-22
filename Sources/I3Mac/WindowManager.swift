// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mac-i3 contributors

import AppKit
import ApplicationServices
import I3Config
import I3Core

public struct ManagerOptions {
    /// Only manage apps matching one of these names / bundle ids (empty = all apps).
    public var only: [String] = []
    public var exclude: [String] = []
    public var configPath: String?
    public var verbose = false
    public init() {}
}

/// The daemon: mirrors OS windows into an `I3Core.Tree`, applies the computed layout through the
/// Accessibility API, and turns key chords / IPC messages into i3 commands.
public final class WindowManager {
    struct Win {
        let element: AXUIElement
        let pid: pid_t
    }

    let opts: ManagerOptions
    var tree: Tree
    var config = Config()
    var mode = "default"
    var bindingIndex: [String: [UInt32: KeyBinding]] = [:]

    var wins: [WindowID: Win] = [:]
    var applied: [WindowID: Rect] = [:]
    var retries: [WindowID: Int] = [:]
    var parked = Set<WindowID>()
    var observers: [pid_t: AXObserver] = [:]

    var lastOSFocus: WindowID?
    /// The tree's focused window at the last layout pass; a change means we must move OS focus.
    var lastAppliedFocus: WindowID?
    var focusPushedAt = Date.distantPast
    var reconcilePending = false
    /// Set when a rule moved a new window away from the focus, so OS focus must be restored, not adopted.
    var reclaimFocus = false
    var lastOutputs: [String] = []
    var mouseMonitor: Any?
    /// `start()` has run (windows are being managed). Guards against starting twice and against sweeping windows on quit.
    var started = false
    var permissionTimer: Timer?
    /// The workspace list in the menu bar.
    var bar: WorkspaceBarController?
    /// Set when a command (closing a window) will move focus a moment later: the cursor should follow then.
    var warpUntil = Date.distantPast
    var warpAway: WindowID?
    /// When a known window was first not listed (see `reconcile`); cleared once it is seen again.
    var missingSince: [WindowID: Date] = [:]
    /// When a known window's owning process was first observed missing from `NSWorkspace.runningApplications`;
    /// cleared the moment that process is seen alive again (see `reconcile`).
    var ownerMissingSince: [WindowID: Date] = [:]
    /// While `Date() < sleepGuardUntil`, no window is ever removed, regardless of what any AX call reports.
    /// Observed on real hardware: as the system begins to sleep, `AXUIElementCopyAttributeValue` returns
    /// `.invalidUIElement` for *every* window at once — the display/WindowServer connection tearing down, not
    /// the windows actually closing — which briefly makes every "is this really gone?" signal this file relies
    /// on lie at the same time. Nothing computed from AX can be trusted to tell that moment apart from a real
    /// closure, so this guard uses the one authoritative, non-AX source instead: the OS's own sleep/wake
    /// notifications (plus a large gap between reconcile ticks, in case a notification is ever missed).
    var sleepGuardUntil = Date.distantPast
    var lastReconcileAt = Date()
    var gesture: Gesture?
    /// Frame verification pauses while the mouse is in use, so it cannot undo a drag before it is read.
    var lastMouseActivity = Date.distantPast

    let keyTap = KeyTap()
    let ipc = IPCServer()
    var overlay: OverlayController?
    let myPid = getpid()

    public init(options: ManagerOptions) {
        opts = options
        tree = Tree(outputs: Displays.outputs())
        lastOutputs = describeOutputs(Displays.outputs())
        tree.setOutputLabels(Displays.labels(), primary: Displays.primaryName())
    }

    func log(_ s: String) { if opts.verbose { FileHandle.standardError.write(Data(("[mac-i3] " + s + "\n").utf8)) } }

    // MARK: - Lifecycle

    /// Starts everything and runs the main loop forever.
    public func run() -> Never {
        AppInfo.redirectLogsIfBundled()
        if IPC.send("ping", timeout: 1) == "pong" {
            if AppInfo.isBundled {
                NSApplication.shared.setActivationPolicy(.accessory)
                AppInfo.alert("mac-i3 is already running", "Look for its icon in the menu bar.", buttons: ["OK"])
            } else {
                FileHandle.standardError.write(Data("mac-i3: already running.\n".utf8))
            }
            exit(1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        installSignalHandlers()
        if !AXIsProcessTrusted() {
            guard AppInfo.isBundled else {
                FileHandle.standardError.write(Data("mac-i3: Accessibility permission missing for the app that launched it (your terminal). Run `mac-i3 doctor`.\n".utf8))
                exit(1)
            }
            waitForPermissions()
        } else {
            start()
        }
        app.run()
        exit(0)
    }

    /// Running as an app without access yet: keep a warning glyph in the menu bar, explain once, register in the
    /// Privacy lists, and start by itself the moment Accessibility is granted. The watcher is started first and runs
    /// in every run-loop mode, so it notices the grant even while the explanation is still on screen.
    func waitForPermissions() {
        ensureBar().setNeedsPermission(true)
        AppInfo.note("Accessibility permission missing: waiting for it (Input Monitoring: \(AppInfo.inputMonitoringAllowed ? "allowed" : "not allowed"))")
        var alertOpen = false
        let watcher = Timer(timeInterval: 1, repeats: true) { [weak self] t in
            guard let self, AppInfo.accessibilityAllowed else { return }
            t.invalidate()
            self.permissionTimer = nil
            AppInfo.note("Accessibility permission granted")
            if alertOpen { NSApp.abortModal() }
            self.start()
        }
        RunLoop.main.add(watcher, forMode: .common)
        permissionTimer = watcher

        alertOpen = true
        let choice = AppInfo.alert(
            "mac-i3 needs two permissions",
            "macOS only lets an app move windows and see keyboard shortcuts after you allow it:\n\n"
            + "• Accessibility: to move, resize and focus windows\n"
            + "• Input Monitoring: to react to your key bindings\n\n"
            + "Click Continue, then turn on “mac-i3” in each list. It starts by itself as soon as access is granted.\n\n"
            + "If mac-i3 is already in a list (even switched on) from an earlier install, select it and click − to remove it, "
            + "then quit and reopen mac-i3. macOS ties the permission to the exact build.",
            buttons: ["Continue", "Quit"])
        alertOpen = false
        if choice == 1 { exit(0) }
        if choice == 0 && !started {
            AppInfo.requestPermissions()
            AppInfo.openSettings(AppInfo.accessibilityPane)
        }
    }

    /// Everything that needs the permissions: the tree, config, key tap, mouse monitor, timers.
    func start() {
        guard !started else { return }
        started = true
        let ov = OverlayController()
        ov.onTabClick = { [weak self] id in
            guard let self else { return }
            self.tree.focusWindow(id)
            self.applyLayout()
        }
        overlay = ov

        loadConfig()
        guard ipc.start() else { die("cannot open IPC socket at \(IPC.socketPath)") }
        ipc.handler = { [weak self] req in self?.handleIPC(req) ?? "error" }

        keyTap.handler = { [weak self] code, mods, down in self?.handleKey(code, mods, down) ?? false }
        if keyTap.start() {
            bar?.setNeedsPermission(false)
        } else if AppInfo.isBundled {
            AppInfo.note("key tap could not start yet (Accessibility \(AppInfo.accessibilityAllowed ? "allowed" : "not allowed"), Input Monitoring \(AppInfo.inputMonitoringAllowed ? "allowed" : "not allowed")); retrying")
            bar?.setNeedsPermission(true)
            var waited = 0
            var told = false
            let retry = Timer(timeInterval: 2, repeats: true) { [weak self] t in
                guard let self else { return }
                if self.keyTap.start() {
                    t.invalidate()
                    AppInfo.note("key bindings active")
                    self.bar?.setNeedsPermission(false)
                    return
                }
                waited += 2
                // macOS says Input Monitoring is allowed, yet the tap still cannot start: it applies the grant to a
                // freshly launched process, so relaunch once automatically (never in a loop).
                if waited >= 6, AppInfo.inputMonitoringAllowed {
                    if ProcessInfo.processInfo.environment["MAC_I3_RELAUNCHED"] == nil {
                        AppInfo.note("Input Monitoring is allowed but not applied to this process yet: relaunching once")
                        setenv("MAC_I3_RELAUNCHED", "1", 1)
                        self.perform(.restart)
                    } else if !told {
                        told = true
                        AppInfo.note("key tap still failing after a relaunch")
                        AppInfo.alert("Please quit and reopen mac-i3",
                                      "macOS has allowed Input Monitoring, but it only takes effect after mac-i3 is opened again. Choose Quit mac-i3 from its menu bar item and open it from Applications.",
                                      buttons: ["OK"])
                    }
                }
            }
            RunLoop.main.add(retry, forMode: .common)
        } else {
            FileHandle.standardError.write(Data("mac-i3: could not create key tap (Input Monitoring permission?). Key bindings disabled.\n".utf8))
        }

        installMouseMonitor()
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                  NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                  NSWorkspace.didUnhideApplicationNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.requestReconcile() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.requestReconcile()
        }
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            AppInfo.note("system is going to sleep: no window will be removed until well after it wakes")
            self.sleepGuardUntil = .distantFuture
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            AppInfo.note("system woke up; giving every window a fresh grace period before reconciling")
            self.missingSince.removeAll()
            self.ownerMissingSince.removeAll()
            self.sleepGuardUntil = Date().addingTimeInterval(4)   // AX/WindowServer needs a moment to settle
            self.lastReconcileAt = Date()
            self.requestReconcile()
        }
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.reconcile() }
        // A general safety net, independent of the display-change hook above: covers any other way the item
        // could end up missing that a display reconfiguration is not the trigger for.
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.bar?.verifyPresence() }

        restoreOffscreenWindows(quiet: true)   // recover from a previous crash
        let restore = attemptRestore()
        reconcile(prefetched: restore.map { ($0.found, $0.unavailable) }, forceApply: (restore?.restored ?? 0) > 0)
        for cmd in config.startup { execShell(cmd) }
        log("running; \(tree.allWindowIDs.count) windows managed")
    }

    // MARK: - Layout persistence

    /// One-shot: reconstructs the tree from the last saved snapshot before the very first `reconcile()`,
    /// so windows that already existed land back in their saved splits/tabs/stacks instead of getting
    /// tiled in fresh. Windows the snapshot does not account for are simply left for `reconcile()` to add
    /// in the usual way, right after this returns.
    /// Returns the enumeration it had to do anyway (to match the snapshot against what is actually running),
    /// so the caller's first `reconcile()` can reuse it instead of paying for a second full AX pass over every
    /// app — otherwise the bar sits on its startup placeholder for twice as long after every `restart`.
    @discardableResult
    func attemptRestore() -> (found: [Found], unavailable: Set<pid_t>, restored: Int)? {
        guard config.layoutPersistence,
              let data = try? Data(contentsOf: URL(fileURLWithPath: AppInfo.statePath)),
              let snapshot = try? JSONDecoder().decode(TreeSnapshot.self, from: data) else { return nil }
        let result = enumerate()
        for f in result.found { wins[f.id] = Win(element: f.element, pid: f.pid) }
        let live = result.found.map { LiveWindow(id: $0.id, appName: $0.appName, title: $0.title) }
        let (restored, dropped) = tree.restore(from: snapshot, live: live)
        if restored > 0 {
            log("restored \(restored) window(s) from the saved layout" + (dropped > 0 ? " (\(dropped) no longer present)" : ""))
        }
        return (result.found, result.unavailable, restored)
    }

    /// Writes the current tree to disk, so the next `restart` (or a relaunch after a crash) can restore it.
    func saveSnapshot() {
        guard config.layoutPersistence else { return }
        let snap = tree.snapshot { [wins] id in
            wins[id].flatMap { NSRunningApplication(processIdentifier: $0.pid)?.localizedName }
        }
        guard let data = try? JSONEncoder().encode(snap) else { return }
        let path = AppInfo.statePath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func die(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("mac-i3: \(msg)\n".utf8))
        exit(1)
    }

    var signalSources: [DispatchSourceSignal] = []
    func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in self?.shutdown() }
            s.resume()
            signalSources.append(s)
        }
    }

    func shutdown() -> Never {
        log("shutting down")
        keyTap.stop()
        ipc.stop()
        overlay?.hideAll()
        bar?.remove()
        if started { restoreOffscreenWindows(quiet: true) }   // nothing was parked if we never started managing
        exit(0)
    }

    // MARK: - Config

    func loadConfig() {
        var text = DefaultConfig.text
        let path = opts.configPath ?? NSString(string: "~/.config/mac-i3/config").expandingTildeInPath
        if let user = try? String(contentsOfFile: path, encoding: .utf8) {
            text = user
            log("config: \(path)")
        } else if opts.configPath != nil {
            FileHandle.standardError.write(Data("mac-i3: cannot read config \(path)\n".utf8))
        }
        let r = ConfigParser.parse(text)
        for e in r.errors { FileHandle.standardError.write(Data("mac-i3 config: \(e)\n".utf8)) }
        config = r.config
        bindingIndex = [:]
        for (m, list) in config.modes {
            var idx: [UInt32: KeyBinding] = [:]
            for b in list where !b.release { idx[b.lookupKey] = b }
            bindingIndex[m] = idx
        }
        tree.innerGap = config.innerGap
        tree.outerGap = config.outerGap
        tree.focusWrapping = config.focusWrapping
        tree.setWorkspaceOutputs(config.workspaceOutputs)
        if bindingIndex[mode] == nil { mode = "default" }
        configureBar()
    }

    // MARK: - Workspace bar

    func configureBar() {
        let b = ensureBar()
        b.configure(enabled: config.workspaceBar, icons: config.workspaceBarIcons, layout: config.workspaceBarLayout,
                    glyphWhenDisabled: AppInfo.isBundled)
        updateBar()
    }

    /// The menu bar item; created early so it can also show "needs permission" before the daemon starts.
    @discardableResult
    func ensureBar() -> WorkspaceBarController {
        if let bar { return bar }
        let b = WorkspaceBarController()
        // Clicks on the bar are mouse actions: apply them directly, so `mouse_warping` does not move the cursor.
        b.onSwitch = { [weak self] name in
            guard let self else { return }
            self.tree.switchWorkspace(name)
            self.applyLayout()
        }
        b.onFocusWindow = { [weak self] id in
            guard let self else { return }
            self.tree.focusWindow(id)
            self.applyLayout()
        }
        b.actions = AppActions(reload: { [weak self] in _ = self?.execute("reload") },
                               restart: { [weak self] in self?.perform(.restart) },
                               quit: { [weak self] in self?.shutdown() })
        b.onDiagnostic = { [weak self] msg in AppInfo.note("workspace bar: \(msg)") }
        bar = b
        return b
    }

    func updateBar() {
        guard let bar else { return }
        let summary = tree.barSummary(mode: mode)
        var info: [WindowID: BarWindowInfo] = [:]
        for o in summary.outputs { for w in o.workspaces { for id in w.windows {
            let pid = wins[id]?.pid ?? 0
            info[id] = BarWindowInfo(title: tree.find(id)?.title ?? "", pid: pid,
                                     appName: NSRunningApplication(processIdentifier: pid)?.localizedName ?? "")
        } } }
        bar.update(summary, info: info)
    }

    // MARK: - Input

    func handleKey(_ code: UInt16, _ mods: Modifiers, _ down: Bool) -> Bool {
        guard down, let b = bindingIndex[mode]?[UInt32(mods.rawValue) << 16 | UInt32(code)] else { return false }
        let command = b.command
        DispatchQueue.main.async { [weak self] in
            self?.log("key \(b.chord) -> \(command)")
            _ = self?.execute(command)
        }
        return true
    }

    @discardableResult
    func execute(_ line: String) -> String {
        var errs: [String] = []
        let before = focusSnapshot()
        let actions = tree.run(line, errors: &errs)
        for a in actions { perform(a) }
        let res = applyLayout()
        warpAfterCommand(before: before, layout: res)
        return errs.isEmpty ? "ok" : "error: " + errs.joined(separator: "; ")
    }

    func perform(_ a: Action) {
        switch a {
        case .exec(let cmd): execShell(cmd)
        case .kill(let id):
            closeWindow(id)
            warpAway = id
            warpUntil = Date().addingTimeInterval(2.5)   // focus moves to a neighbour once the window is gone
        case .mode(let m):
            if bindingIndex[m] != nil { mode = m } else { log("unknown mode \(m)") }
        case .reload:
            loadConfig()
            log("config reloaded")
        case .restart:
            keyTap.stop(); ipc.stop()
            restoreOffscreenWindows(quiet: true)
            bar?.remove()
            // A genuinely new process, not execv(): execv keeps this process's PID but does not reset its
            // existing Mach-level connections to WindowServer, and NSStatusBar was observed (reproducibly)
            // to come back permanently broken in the same process after it — no amount of tearing down and
            // recreating the status item fixed it. A fresh child process never inherits that state.
            let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = Array(CommandLine.arguments.dropFirst())
            do {
                try p.run()
                exit(0)
            } catch {
                die("restart failed: \(error)")
            }
        case .exit:
            shutdown()
        }
    }

    func execShell(_ cmd: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { log("exec failed: \(cmd)") }
    }

    func closeWindow(_ id: WindowID) {
        guard let w = wins[id] else { return }
        if let btn = AX.attr(w.element, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
        }
    }

    // MARK: - IPC

    func handleIPC(_ req: String) -> String {
        let r = req.trimmingCharacters(in: .whitespacesAndNewlines)
        switch r {
        case "ping": return "pong"
        case "tree":
            return json(tree.jsonTree())
        case "bar":
            return json(bar?.debugDictionary() ?? ["enabled": false])
        case "state":
            reconcile()
            return json(stateDictionary())
        case "reconcile":
            reconcile()
            return "ok"
        case "debug-simulate-sleep":
            // Test-only: exercises the exact same guard the real willSleep/didWake notifications set, without
            // needing an actual system suspend. Never reachable except by deliberately sending this over IPC.
            sleepGuardUntil = .distantFuture
            return "ok"
        case "debug-simulate-wake":
            missingSince.removeAll()
            ownerMissingSince.removeAll()
            sleepGuardUntil = Date().addingTimeInterval(4)
            lastReconcileAt = Date()
            return "ok"
        case "debug-break-bar":
            // Test-only: reproduces "macOS silently dropped the status item" without needing a real display
            // change, by pulling the item out from under our own bookkeeping's feet.
            bar?.debugBreak()
            return "ok"
        case "debug-verify-bar":
            bar?.verifyPresence()
            return "ok"
        case "shape":
            return tree.outputs.map { o in tree.currentWorkspace(of: o) }.map { "\($0.name): \(tree.shape($0))" }.joined(separator: "\n")
        default:
            return execute(r)
        }
    }

    func json(_ obj: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    /// Ground truth for tests: model shape plus the frames the OS reports right now.
    func stateDictionary() -> [String: Any] {
        var windows: [[String: Any]] = []
        for id in tree.allWindowIDs.sorted() {
            guard let con = tree.find(id) else { continue }
            var d: [String: Any] = ["id": Int(id), "title": con.title, "floating": con.isFloating,
                                    "workspace": con.workspace?.name ?? "", "focused": tree.focusedWindowID == id,
                                    "parked": parked.contains(id)]
            if let w = wins[id], let f = AX.frame(w.element) {
                d["frame"] = ["x": f.x, "y": f.y, "w": f.w, "h": f.h]
            }
            if let r = applied[id] { d["desired"] = ["x": r.x, "y": r.y, "w": r.w, "h": r.h] }
            windows.append(d)
        }
        return [
            "mode": mode,
            "osFocus": osFocusedWindowID().map { Int($0) } ?? NSNull(),
            "workspace": tree.activeWorkspace.name,
            "output": tree.activeOutput.name,
            "shape": tree.outputs.map { "\($0.name)/\(tree.currentWorkspace(of: $0).name): \(tree.shape(tree.currentWorkspace(of: $0)))" },
            "workspaces": tree.outputs.flatMap { $0.children.map { "\($0.name): \(tree.shape($0))" } },
            "outputs": tree.outputs.map { out in ["name": out.name, "label": out.title, "number": (tree.numberedOutputs.firstIndex(where: { $0 === out }) ?? 0) + 1, "primary": out.name == tree.primaryOutputName,
                                           "workspace": tree.currentWorkspace(of: out).name,
                                           "x": out.rect.x, "y": out.rect.y, "w": out.rect.w, "h": out.rect.h] as [String: Any] },
            "windows": windows,
        ]
    }

    // MARK: - Window discovery

    func matches(_ app: NSRunningApplication) -> Bool {
        let names = [app.localizedName, app.bundleIdentifier, app.executableURL?.lastPathComponent]
            .compactMap { $0?.lowercased() }
        if !opts.only.isEmpty && !opts.only.contains(where: { names.contains($0.lowercased()) }) { return false }
        if opts.exclude.contains(where: { names.contains($0.lowercased()) }) { return false }
        return true
    }

    struct Found {
        let id: WindowID
        let element: AXUIElement
        let pid: pid_t
        let title: String
        let floating: Bool
        let frame: Rect?
        let appName: String
    }

    /// `unavailable`: pids whose window list could not be retrieved this pass (app busy, suspended, or still
    /// waking from sleep) — the caller must not treat any of their previously known windows as removed.
    func enumerate() -> (found: [Found], unavailable: Set<pid_t>) {
        var out: [Found] = []
        var unavailable: Set<pid_t> = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != myPid && !app.isTerminated && !app.isHidden && matches(app) {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.5)
            ensureObserver(app, axApp)
            guard let list = AX.attr(axApp, kAXWindowsAttribute) as? [AXUIElement] else {
                log("AX window list unavailable for \(app.localizedName ?? "?") (pid \(app.processIdentifier))")
                unavailable.insert(app.processIdentifier)
                continue
            }
            for w in list {
                guard AX.string(w, kAXRoleAttribute) == kAXWindowRole,
                      AX.bool(w, kAXMinimizedAttribute) != true,
                      AX.bool(w, "AXFullScreen") != true,
                      let id = AX.windowID(w) else { continue }
                let subrole = AX.string(w, kAXSubroleAttribute) ?? ""
                var floating = false
                switch subrole {
                case kAXStandardWindowSubrole: floating = !AX.isSettable(w, kAXSizeAttribute)
                case kAXDialogSubrole, kAXFloatingWindowSubrole, kAXSystemDialogSubrole: floating = true
                default: continue
                }
                AX.boundMessaging(w)   // never let a later call through this cached reference hang the daemon
                if let f = AX.frame(w), f.w < 60 || f.h < 40 { continue }
                out.append(Found(id: id, element: w, pid: app.processIdentifier,
                                 title: AX.string(w, kAXTitleAttribute) ?? "", floating: floating,
                                 frame: AX.frame(w), appName: app.localizedName ?? ""))
            }
        }
        return (out, unavailable)
    }

    // MARK: - Observers

    func ensureObserver(_ app: NSRunningApplication, _ axApp: AXUIElement) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }
        var obs: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &obs) == .success, let o = obs else { return }
        let ref = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                  kAXApplicationHiddenNotification, kAXApplicationShownNotification, kAXWindowMiniaturizedNotification,
                  kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(o, axApp, n as CFString, ref)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes)
        observers[pid] = o
    }

    func pruneObservers(_ alive: Set<pid_t>) {
        for pid in observers.keys where !alive.contains(pid) { observers[pid] = nil }
    }

    func requestReconcile() {
        guard !reconcilePending else { return }
        reconcilePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.reconcilePending = false
            self?.reconcile()
        }
    }

    // MARK: - Reconcile OS state into the tree

    /// `forceApply`: a restored snapshot changed the tree's structure without the OS-facing signals below ever
    /// seeing a window added, removed or moved — nothing here would otherwise set `changed`, so the restored
    /// layout (and the bar) would never actually get pushed out until something unrelated forced an `applyLayout()`.
    func reconcile(prefetched: (found: [Found], unavailable: Set<pid_t>)? = nil, forceApply: Bool = false) {
        // A gap much larger than the 0.4s timer cadence is circumstantial evidence of a suspend we may not have
        // received (or not yet processed) a notification for — guard defensively, the same as an explicit one.
        let now = Date()
        if now.timeIntervalSince(lastReconcileAt) > 2, sleepGuardUntil < now.addingTimeInterval(4) {
            AppInfo.note("reconcile was delayed \(Int(now.timeIntervalSince(lastReconcileAt)))s — likely a suspend; guarding removals defensively")
            sleepGuardUntil = now.addingTimeInterval(4)
        }
        lastReconcileAt = now

        // A pid missing here usually means its whole process has exited — the fastest available signal that any
        // of its windows are gone — but a single reading of this list is not enough to act on (see below).
        let alivePids = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
        pruneObservers(alivePids)
        var changed = forceApply

        let outs = Displays.outputs()
        let desc = describeOutputs(outs)
        if desc != lastOutputs {
            AppInfo.note("displays changed: \(lastOutputs) -> \(desc)")
            lastOutputs = desc
            tree.updateOutputs(outs, labels: Displays.labels(), primary: Displays.primaryName())
            applied.removeAll()
            changed = true
            // The status item is anchored to a particular screen's menu bar; give macOS a moment to finish
            // laying that out after the reconfiguration before checking whether ours survived it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.bar?.verifyPresence() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in self?.bar?.verifyPresence() }
        }

        let (found, unavailableApps) = prefetched ?? enumerate()
        let foundIDs = Set(found.map { $0.id })
        for id in foundIDs { missingSince[id] = nil }
        for id in foundIDs where wins[id].map({ alivePids.contains($0.pid) }) ?? true { ownerMissingSince[id] = nil }
        for id in tree.allWindowIDs where !foundIDs.contains(id) {
            // Mid-sleep, or shortly after waking: every AX signal below is suspect (see `sleepGuardUntil`), so no
            // verdict is reached at all this pass — not even the generous grace period is allowed to expire.
            if Date() < sleepGuardUntil { missingSince[id] = nil; continue }
            // Its app could not even list its windows this pass (busy, suspended, or still waking from sleep):
            // we have no information at all about this window, so it is left exactly as it is.
            if let pid = wins[id]?.pid, unavailableApps.contains(pid) { continue }
            // A confirmed-dead element (the app answered, and this handle is definitively invalid) is removed
            // right away. Anything less certain — the app is merely slow to answer about this one window — gets
            // a generous, wall-clock grace period (not a pass count, so it is immune to any timing jitter),
            // comfortably covering a real sleep/wake cycle, before we give up and remove it anyway.
            let firstMissed = missingSince[id] ?? Date()
            missingSince[id] = firstMissed
            let w = wins[id]
            // Two independent "confirmed gone" signals, each trusted only once it is not just a single momentary
            // reading (observed, in a real sleep/wake cycle, to happen: `NSWorkspace.runningApplications`
            // transiently omitted a process that had never actually exited):
            //  - the owning process is missing from NSWorkspace.runningApplications, persistently, not just once;
            //  - the cached AX element reports itself definitely invalid (rare in practice — once a whole process
            //    has exited, calls through its old elements tend to just fail some other way — but trusted at once
            //    on the odd occasion it does happen, since it is unambiguous).
            let ownerMissingNow = w.map { !alivePids.contains($0.pid) } ?? true
            if ownerMissingNow { ownerMissingSince[id] = ownerMissingSince[id] ?? Date() } else { ownerMissingSince[id] = nil }
            let ownerConfirmedGone = ownerMissingSince[id].map { Date().timeIntervalSince($0) >= 0.9 } ?? false
            let elementConfirmedGone = w.map { !AX.exists($0.element) } ?? true
            let goneForSure = ownerConfirmedGone || elementConfirmedGone
            if !goneForSure, Date().timeIntervalSince(firstMissed) < 5 {
                log("? window \(id) not listed (ownerMissingNow=\(ownerMissingNow) elementConfirmedGone=\(elementConfirmedGone)); keeping it for now")
                continue
            }
            log("- window \(id) \"\(tree.find(id)?.title ?? "")\" gone (ownerConfirmedGone=\(ownerConfirmedGone) elementConfirmedGone=\(elementConfirmedGone) waited=\(Date().timeIntervalSince(firstMissed))s)")
            missingSince[id] = nil
            ownerMissingSince[id] = nil
            tree.removeWindow(id)
            wins[id] = nil; applied[id] = nil; retries[id] = nil; parked.remove(id)
            changed = true
        }
        for f in found.sorted(by: { $0.id < $1.id }) where tree.find(f.id) == nil {
            wins[f.id] = Win(element: f.element, pid: f.pid)
            tree.addWindow(f.id, title: f.title, floating: f.floating, rect: f.floating ? f.frame : nil)
            applyRules(for: f)
            log("+ window \(f.id) \"\(f.title)\" (\(f.appName))\(f.floating ? " floating" : "")")
            changed = true
        }
        for f in found {
            guard let con = tree.find(f.id) else { continue }
            wins[f.id] = Win(element: f.element, pid: f.pid)
            if con.title != f.title { con.title = f.title; changed = true }
            // A floating window moved by the user keeps its new frame.
            if con.isFloating, let actual = f.frame, let want = applied[f.id], !nearlyEqual(actual, want, 4), !parked.contains(f.id) {
                tree.floatingFrameChanged(f.id, actual)
                applied[f.id] = actual
            }
        }
        if reclaimFocus {
            reclaimFocus = false
            lastAppliedFocus = nil
            focusPushedAt = Date()
            changed = true
        } else if syncFocusFromOS() { changed = true }
        if changed { applyLayout() } else { verifyFrames() }
    }

    func describeOutputs(_ o: [(name: String, rect: Rect)]) -> [String] {
        o.map { "\($0.name)@\($0.rect.x),\($0.rect.y),\($0.rect.w),\($0.rect.h)" }
    }

    /// Adopt focus changes made by the user (mouse click, Cmd-Tab), not ones we just requested.
    func syncFocusFromOS() -> Bool {
        // Right after we moved focus ourselves the OS may still report the old window; ignore that
        // sample entirely (do not record it), so a click made in that moment is still adopted later.
        guard Date().timeIntervalSince(focusPushedAt) > 0.5 else { return false }
        let os = osFocusedWindowID()
        defer { lastOSFocus = os }
        guard let os, os != lastOSFocus else { return false }
        guard tree.find(os) != nil else { return false }
        lastAppliedFocus = os
        if tree.focusedWindowID == os { return false }
        tree.focusWindow(os)
        return true
    }

    func osFocusedWindowID() -> WindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != myPid else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        guard let w = AX.attr(axApp, kAXFocusedWindowAttribute) else { return nil }
        return AX.windowID(w as! AXUIElement)
    }

    func nearlyEqual(_ a: Rect, _ b: Rect, _ tol: Double) -> Bool {
        abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol && abs(a.w - b.w) <= tol && abs(a.h - b.h) <= tol
    }

    // MARK: - Rules (for_window / assign, subset)

    func applyRules(for f: Found) {
        for rule in config.forWindow + config.assign where Criteria(rule.criteria).matches(app: f.appName, title: f.title) {
            var cmd = rule.command
            if config.assign.contains(where: { $0.criteria == rule.criteria && $0.command == rule.command }) {
                cmd = "move container to workspace " + cmd.replacingOccurrences(of: "→", with: "").trimmingCharacters(in: .whitespaces)
            }
            _ = tree.run(cmd)
        }
        // A rule that floats a window leaves it where the app put it (a key-press toggle would instead
        // shrink it), so `for_window [class=".*"] floating enable` does not pile everything up.
        if !f.floating, let frame = f.frame, tree.find(f.id)?.isFloating == true {
            tree.floatingFrameChanged(f.id, frame)
        }
        if tree.focusedWindowID != f.id { reclaimFocus = true }
    }

    // MARK: - Applying the layout

    /// Where inactive windows go: the bottom-right corner of the right-most display, so only a
    /// 1px corner stays on screen (macOS refuses to place a window completely off every display).
    var parkPoint: (x: Double, y: Double) {
        guard let s = Displays.fullFrames().max(by: { $0.maxX < $1.maxX || ($0.maxX == $1.maxX && $0.maxY < $1.maxY) }) else { return (0, 0) }
        return (s.maxX - 1, s.maxY - 1)
    }

    @discardableResult
    public func applyLayout() -> LayoutResult {
        let res = tree.computeLayout()
        let pp = parkPoint
        for id in res.hidden {
            guard let w = wins[id], !parked.contains(id) else { continue }
            AX.setPosition(w.element, x: pp.x, y: pp.y)
            parked.insert(id)
            applied[id] = nil
        }
        for (id, r) in res.frames {
            guard let w = wins[id] else { continue }
            if parked.contains(id) || applied[id] != r {
                AX.setFrame(w.element, r)
                applied[id] = r
                retries[id] = 0
                parked.remove(id)
            }
        }
        overlay?.update(bars: res.bars, tree: tree)
        pushFocus(res)
        warpAfterWindowClosed(layout: res)
        updateBar()
        saveSnapshot()
        return res
    }

    func pushFocus(_ res: LayoutResult) {
        let target = res.focusedWindow
        defer { lastAppliedFocus = target }
        guard let id = target, id != lastAppliedFocus, let w = wins[id] else { return }
        focusPushedAt = Date()
        let app = AXUIElementCreateApplication(w.pid)
        AX.set(app, kAXFrontmostAttribute, kCFBooleanTrue)
        AX.set(w.element, kAXMainAttribute, kCFBooleanTrue)
        AX.set(w.element, kAXFocusedAttribute, kCFBooleanTrue)
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        lastOSFocus = id
    }

    /// Snap windows back if something (or the user) moved them; give up after a few tries so
    /// apps with minimum sizes / cell-grid snapping (Terminal) do not fight us forever.
    func verifyFrames() {
        guard NSEvent.pressedMouseButtons == 0, Date().timeIntervalSince(lastMouseActivity) > 0.6 else { return }
        for (id, want) in applied {
            guard !parked.contains(id), let w = wins[id], (retries[id] ?? 0) < 2, let actual = AX.frame(w.element) else { continue }
            if let con = tree.find(id), con.isFloating { continue }
            let posOff = abs(actual.x - want.x) > 3 || abs(actual.y - want.y) > 3
            let sizeOff = abs(actual.w - want.w) > 40 || abs(actual.h - want.h) > 40
            if posOff || sizeOff {
                retries[id, default: 0] += 1
                AX.setFrame(w.element, want)
            }
        }
    }

    // MARK: - Recovering windows

    /// Pull every window that is entirely off all displays back onto the primary display.
    @discardableResult
    public func restoreOffscreenWindows(quiet: Bool) -> Int {
        // Only rescue windows this daemon could have parked (respects --only/--exclude), so a scoped
        // instance never disturbs windows parked by another one.
        WindowManager.restoreOffscreen(quiet: quiet, appFilter: { [self] in matches($0) })
    }

    @discardableResult
    public static func restoreOffscreen(quiet: Bool, appFilter: (NSRunningApplication) -> Bool = { _ in true }) -> Int {
        let screens = Displays.fullFrames()
        guard let main = Displays.outputs().first?.rect else { return 0 }
        var moved = 0
        var n = 0.0
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() && appFilter(app) {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.5)
            guard let list = AX.attr(axApp, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for w in list {
                guard let f = AX.frame(w) else { continue }
                let visible = screens.contains { s in f.x < s.maxX - 20 && f.maxX > s.x + 20 && f.y < s.maxY - 20 && f.maxY > s.y + 20 }
                if visible { continue }
                let width = min(f.w, main.w * 0.8), height = min(f.h, main.h * 0.8)
                AX.setFrame(w, Rect(main.x + 40 + n * 24, main.y + 40 + n * 24, width, height))
                n += 1; moved += 1
                if !quiet { print("restored \(app.localizedName ?? "?"): \(AX.string(w, kAXTitleAttribute) ?? "")") }
            }
        }
        return moved
    }
}

private func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue().requestReconcile()
}
