import AppKit
import I3Core

/// `mac-i3 bar-preview <file.png> [dark] [flat]`: renders a sample workspace bar offscreen (no daemon needed).
public enum BarPreview {
    public static func write(to path: String, dark: Bool, layout: String, crowded: Bool = false) -> Bool {
        let t = Tree(outputs: [("display-1", Rect(0, 0, 1800, 1100)), ("display-2", Rect(1800, 0, 1920, 1080))])
        t.setOutputLabels([:], primary: "display-1")
        // Workspace 1, the example h[chrome term] t[chrome v[chrome chrome]]
        t.addWindow(1); t.addWindow(2)
        t.run("focus parent"); t.run("split h")
        t.addWindow(3); t.run("split h"); t.run("layout tabbed")
        t.addWindow(4); t.run("split v"); t.addWindow(5)
        // Workspace 3 (showing on the primary display): one window
        t.run("workspace 3"); t.addWindow(8)
        // Workspace 2 on the second display: a tabbed pair, floating window
        t.run("focus output 2"); t.addWindow(6); t.addWindow(7); t.run("layout tabbed")
        t.addWindow(9, floating: true)
        t.run("focus output 1")

        if crowded {
            // Nine busy workspaces on one display: the bar must degrade instead of growing without bound.
            for ws in 1...9 {
                t.run("workspace \(ws)")
                let base = WindowID(ws * 10)
                t.addWindow(base + 1); t.addWindow(base + 2)
                t.run("split v"); t.addWindow(base + 3)
                t.run("layout tabbed"); t.addWindow(base + 4)
            }
            t.run("workspace 5")
        }
        func pid(_ names: [String]) -> pid_t {
            for n in names {
                if let a = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == n && $0.activationPolicy == .regular }) {
                    return a.processIdentifier
                }
            }
            return NSRunningApplication.current.processIdentifier
        }
        let chrome = pid(["Google Chrome", "Safari"]), term = pid(["Terminal", "iTerm2"]), code = pid(["Code", "Visual Studio Code"])
        let finder = pid(["Finder"]), slack = pid(["Slack"])
        var owners: [WindowID: pid_t] = [1: chrome, 2: term, 3: chrome, 4: chrome, 5: chrome, 6: code, 7: term, 8: finder, 9: slack]
        for id in t.allWindowIDs where owners[id] == nil { owners[id] = [chrome, term, code, finder, slack][Int(id) % 5] }
        var info: [WindowID: BarWindowInfo] = [:]
        for (id, p) in owners { info[id] = BarWindowInfo(title: "", pid: p, appName: NSRunningApplication(processIdentifier: p)?.localizedName ?? "") }

        guard let r = WorkspaceBarController.render(t.barSummary(mode: dark ? "resize" : "default"), info: info, dark: dark, layout: layout),
              let png = r.rep.representation(using: .png, properties: [:]) else { return false }
        print("width \(Int(r.width))pt; \(r.detail)")
        do { try png.write(to: URL(fileURLWithPath: path)); return true } catch { return false }
    }
}
