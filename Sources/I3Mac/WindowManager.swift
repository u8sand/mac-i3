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

    let keyTap = KeyTap()
    let ipc = IPCServer()
    var overlay: OverlayController?
    let myPid = getpid()

    public init(options: ManagerOptions) {
        opts = options
        tree = Tree(outputs: Displays.outputs())
        lastOutputs = describeOutputs(Displays.outputs())
    }

    func log(_ s: String) { if opts.verbose { FileHandle.standardError.write(Data(("[mac-i3] " + s + "\n").utf8)) } }

    // MARK: - Lifecycle

    /// Starts everything and runs the main loop forever.
    public func run() -> Never {
        guard AXIsProcessTrusted() else {
            FileHandle.standardError.write(Data("mac-i3: Accessibility permission missing. Run `mac-i3 doctor`.\n".utf8))
            exit(1)
        }
        if IPC.send("ping", timeout: 1) == "pong" {
            FileHandle.standardError.write(Data("mac-i3: already running.\n".utf8))
            exit(1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
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
        if !keyTap.start() { FileHandle.standardError.write(Data("mac-i3: could not create key tap (Input Monitoring permission?). Key bindings disabled.\n".utf8)) }

        installSignalHandlers()
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                  NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                  NSWorkspace.didUnhideApplicationNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.requestReconcile() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.requestReconcile()
        }
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.reconcile() }

        restoreOffscreenWindows(quiet: true)   // recover from a previous crash
        reconcile()
        for cmd in config.startup { execShell(cmd) }
        log("running; \(tree.allWindowIDs.count) windows managed")
        app.run()
        exit(0)
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
        restoreOffscreenWindows(quiet: true)
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
        if bindingIndex[mode] == nil { mode = "default" }
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
        let actions = tree.run(line, errors: &errs)
        for a in actions { perform(a) }
        // Commands may act on windows that vanished; reconcile first so the tree is truthful.
        applyLayout()
        return errs.isEmpty ? "ok" : "error: " + errs.joined(separator: "; ")
    }

    func perform(_ a: Action) {
        switch a {
        case .exec(let cmd): execShell(cmd)
        case .kill(let id): closeWindow(id)
        case .mode(let m):
            if bindingIndex[m] != nil { mode = m } else { log("unknown mode \(m)") }
        case .reload:
            loadConfig()
            log("config reloaded")
        case .restart:
            keyTap.stop(); ipc.stop()
            restoreOffscreenWindows(quiet: true)
            let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
            var args = CommandLine.arguments.map { strdup($0) } + [nil]
            execv(exe, &args)
            die("restart failed")
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
        case "state":
            reconcile()
            return json(stateDictionary())
        case "reconcile":
            reconcile()
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
            "outputs": tree.outputs.map { ["name": $0.name, "x": $0.rect.x, "y": $0.rect.y, "w": $0.rect.w, "h": $0.rect.h] as [String: Any] },
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

    func enumerate() -> [Found] {
        var out: [Found] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != myPid && !app.isTerminated && !app.isHidden && matches(app) {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.5)
            ensureObserver(app, axApp)
            guard let list = AX.attr(axApp, kAXWindowsAttribute) as? [AXUIElement] else { continue }
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
                if let f = AX.frame(w), f.w < 60 || f.h < 40 { continue }
                out.append(Found(id: id, element: w, pid: app.processIdentifier,
                                 title: AX.string(w, kAXTitleAttribute) ?? "", floating: floating,
                                 frame: AX.frame(w), appName: app.localizedName ?? ""))
            }
        }
        return out
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

    func pruneObservers() {
        let alive = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
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

    func reconcile() {
        pruneObservers()
        var changed = false

        let outs = Displays.outputs()
        let desc = describeOutputs(outs)
        if desc != lastOutputs {
            lastOutputs = desc
            tree.updateOutputs(outs)
            applied.removeAll()
            changed = true
        }

        let found = enumerate()
        let foundIDs = Set(found.map { $0.id })
        for id in tree.allWindowIDs where !foundIDs.contains(id) {
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
        let os = osFocusedWindowID()
        defer { lastOSFocus = os }
        guard Date().timeIntervalSince(focusPushedAt) > 0.5, let os, os != lastOSFocus else { return false }
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
        for rule in config.forWindow + config.assign where ruleMatches(rule.criteria, f) {
            var cmd = rule.command
            if config.assign.contains(where: { $0.criteria == rule.criteria && $0.command == rule.command }) {
                cmd = "move container to workspace " + cmd.replacingOccurrences(of: "→", with: "").trimmingCharacters(in: .whitespaces)
            }
            _ = tree.run(cmd)
        }
        if tree.focusedWindowID != f.id { reclaimFocus = true }
    }

    func ruleMatches(_ criteria: String, _ f: Found) -> Bool {
        let body = criteria.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        for part in body.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            guard kv.count == 2 else { continue }
            let value = kv[1]
            switch kv[0] {
            case "class", "app", "app_name", "instance": if f.appName.caseInsensitiveCompare(value) != .orderedSame { return false }
            case "title": if !f.title.contains(value) { return false }
            default: return false
            }
        }
        return true
    }

    // MARK: - Applying the layout

    /// Where inactive windows go: the bottom-right corner of the right-most display, so only a
    /// 1px corner stays on screen (macOS refuses to place a window completely off every display).
    var parkPoint: (x: Double, y: Double) {
        guard let s = Displays.fullFrames().max(by: { $0.maxX < $1.maxX || ($0.maxX == $1.maxX && $0.maxY < $1.maxY) }) else { return (0, 0) }
        return (s.maxX - 1, s.maxY - 1)
    }

    public func applyLayout() {
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
        guard NSEvent.pressedMouseButtons == 0 else { return }
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
        WindowManager.restoreOffscreen(quiet: quiet)
    }

    @discardableResult
    public static func restoreOffscreen(quiet: Bool) -> Int {
        let screens = Displays.fullFrames()
        guard let main = Displays.outputs().first?.rect else { return 0 }
        var moved = 0
        var n = 0.0
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() {
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
