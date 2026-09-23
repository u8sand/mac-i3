// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mac-i3 contributors

import Foundation

/// A saved container tree, written after every layout change and read back once at startup, so a
/// `restart` (or recovering from a crash) does not flatten your splits, tabs and stacks back to a plain
/// row. Windows are matched to a saved position primarily by their window ID — unchanged across a
/// `restart`, since the real OS windows never close — and, when that is not found (mac-i3 was quit for a
/// while and some apps relaunched meanwhile), by app name and title as a best-effort fallback. Anything
/// saved that is not found either way is simply dropped, exactly as if you had closed it yourself.
public struct TreeSnapshot: Codable, Equatable {
    public struct Node: Codable, Equatable {
        public var layout: Layout?           // present for a split container, nil for a window
        public var percent: Double
        public var windowID: WindowID?        // for a window
        public var appName: String?           // for a window: fallback match key
        public var title: String?             // for a window: fallback match key
        public var fullscreen: Bool = false    // for a window
        public var children: [Node] = []       // for a split container

        public init(layout: Layout? = nil, percent: Double = 0, windowID: WindowID? = nil, appName: String? = nil,
                    title: String? = nil, fullscreen: Bool = false, children: [Node] = []) {
            self.layout = layout; self.percent = percent; self.windowID = windowID; self.appName = appName
            self.title = title; self.fullscreen = fullscreen; self.children = children
        }
    }
    public struct Floating: Codable, Equatable {
        public var windowID: WindowID?
        public var appName: String?
        public var title: String?
        public var rect: Rect
    }
    public struct Workspace: Codable, Equatable {
        public var name: String
        public var layout: Layout
        public var nodes: [Node]
        public var floating: [Floating]
    }
    public struct Output: Codable, Equatable {
        public var name: String
        public var number: Int
        public var workspaces: [Workspace]
    }
    public var outputs: [Output]
    public var focusedWindowID: WindowID?
    public var focusedAppName: String?
    public var focusedTitle: String?

    public init(outputs: [Output] = [], focusedWindowID: WindowID? = nil, focusedAppName: String? = nil, focusedTitle: String? = nil) {
        self.outputs = outputs; self.focusedWindowID = focusedWindowID
        self.focusedAppName = focusedAppName; self.focusedTitle = focusedTitle
    }
}

/// A currently-live window, as far as the matcher needs to know about it.
public struct LiveWindow {
    public var id: WindowID
    public var appName: String
    public var title: String
    public init(id: WindowID, appName: String, title: String) { self.id = id; self.appName = appName; self.title = title }
}

extension Tree {
    // MARK: - Save

    /// `appName` looks up a window's owning application, when known. I3Core itself has no notion of
    /// "application" (only `Con.title`), so the host (which does) supplies it; without one, snapshots
    /// still round-trip perfectly by window ID — the fallback match just has less to go on.
    public func snapshot(appName: (WindowID) -> String? = { _ in nil }) -> TreeSnapshot {
        let focusLeaf = descendFocused(focused)
        let s = TreeSnapshot(outputs: numberedOutputs.enumerated().map { index, out in
            TreeSnapshot.Output(name: out.name, number: index + 1, workspaces: out.children.map { snapshotWorkspace($0, appName) })
        }, focusedWindowID: focusLeaf.isWindow ? focusLeaf.windowID : nil,
           focusedAppName: focusLeaf.isWindow ? focusLeaf.windowID.flatMap(appName) : nil,
           focusedTitle: focusLeaf.isWindow ? focusLeaf.title : nil)
        return s
    }

    private func snapshotWorkspace(_ ws: Con, _ appName: (WindowID) -> String?) -> TreeSnapshot.Workspace {
        TreeSnapshot.Workspace(name: ws.name, layout: ws.layout, nodes: ws.children.map { snapshotNode($0, appName) },
                               floating: ws.floating.map {
            TreeSnapshot.Floating(windowID: $0.windowID, appName: $0.windowID.flatMap(appName), title: $0.title, rect: $0.rect)
        })
    }

    private func snapshotNode(_ c: Con, _ appName: (WindowID) -> String?) -> TreeSnapshot.Node {
        if c.isWindow {
            return TreeSnapshot.Node(percent: c.percent, windowID: c.windowID, appName: c.windowID.flatMap(appName),
                                     title: c.title, fullscreen: c.fullscreen)
        }
        return TreeSnapshot.Node(layout: c.layout, percent: c.percent, children: c.children.map { snapshotNode($0, appName) })
    }

    // MARK: - Restore

    /// Rebuilds the tree from a saved snapshot, consuming live windows as they are matched. Windows in
    /// `live` that are not mentioned in the snapshot (or that could not be matched) are left untouched,
    /// for the caller to add in the usual way (exactly like a window appearing for the first time).
    /// Safe to call only once, right after the tree is created and before any window has been added.
    @discardableResult
    public func restore(from snapshot: TreeSnapshot, live: [LiveWindow]) -> (restored: Int, dropped: Int) {
        var pool = live
        var restored = 0

        func consume(_ id: WindowID?, _ appName: String?, _ title: String?) -> LiveWindow? {
            if let id, let i = pool.firstIndex(where: { $0.id == id }) { return pool.remove(at: i) }
            if let appName, let title, let i = pool.firstIndex(where: { $0.appName == appName && $0.title == title }) {
                return pool.remove(at: i)
            }
            return nil
        }

        func build(_ node: TreeSnapshot.Node) -> Con? {
            guard let layout = node.layout else {
                guard let w = consume(node.windowID, node.appName, node.title) else { return nil }
                let con = Con(.window)
                con.windowID = w.id
                con.title = w.title
                con.percent = node.percent
                con.fullscreen = node.fullscreen
                restored += 1
                return con
            }
            let kids = node.children.compactMap(build)
            guard !kids.isEmpty else { return nil }   // every window in this container is gone: drop it too
            let con = Con(.split)
            con.layout = layout
            con.lastSplit = layout.isTabLike ? .splitH : layout
            con.percent = node.percent
            for k in kids { con.attach(k) }
            con.fixPercent()
            return con
        }

        func matchOutput(_ saved: TreeSnapshot.Output) -> Con? {
            if let exact = root.children.first(where: { $0.name == saved.name }) { return exact }
            let byPosition = numberedOutputs
            return byPosition.indices.contains(saved.number - 1) ? byPosition[saved.number - 1] : nil
        }

        for savedOut in snapshot.outputs {
            guard let out = matchOutput(savedOut) else { continue }
            for savedWs in savedOut.workspaces {
                let ws = workspace(named: savedWs.name) ?? createWorkspace(savedWs.name, on: out)
                ws.layout = savedWs.layout
                ws.lastSplit = savedWs.layout.isTabLike ? .splitH : savedWs.layout
                for node in savedWs.nodes { if let con = build(node) { ws.attach(con) } }
                ws.fixPercent()
                for f in savedWs.floating {
                    guard let w = consume(f.windowID, f.appName, f.title) else { continue }
                    let con = Con(.window)
                    con.windowID = w.id
                    con.title = w.title
                    con.isFloating = true
                    con.rect = f.rect
                    ws.attach(con)
                    restored += 1
                }
            }
        }

        if let id = snapshot.focusedWindowID, let leaf = find(id) {
            focus(leaf)
        } else if let name = snapshot.focusedAppName, let title = snapshot.focusedTitle {
            // The window ID from before a restart is gone (mac-i3 itself was relaunched by something else,
            // or the window really did close): fall back to whichever restored window matches by title;
            // app name alone is not tracked per window, so this is best-effort, not exact.
            _ = name
            if let leaf = root.children.flatMap({ $0.children }).flatMap({ $0.windows() }).first(where: { $0.title == title }) {
                focus(leaf)
            }
        }

        return (restored, live.count - restored)
    }

    // MARK: - Reinsert (mid-session safety net)

    /// Unlike `restore`, safe to call repeatedly against a tree that already has windows in it: whenever a
    /// live window turns up that the tree does not currently know about (for any reason -- a transient
    /// false "gone" verdict, a display fold, anything), this puts it back where the last saved snapshot
    /// says it was, together with any of its former workspace-mates that are also still missing, instead
    /// of leaving the caller to tile it fresh into whatever workspace happens to be focused right now --
    /// which is what silently collapses windows that go missing and reappear into one flat row. A
    /// workspace that is already fully intact in the live tree is left completely alone: only one that
    /// actually gains a window this call has its saved layout/split orientation reapplied, so a workspace
    /// nothing here concerns keeps whatever the user has since done to it live, even if that has drifted
    /// from what was last saved.
    @discardableResult
    public func reinsert(from snapshot: TreeSnapshot, live: [LiveWindow]) -> Int {
        var pool = live
        var restored = 0

        func consume(_ id: WindowID?, _ appName: String?, _ title: String?) -> LiveWindow? {
            if let id, let i = pool.firstIndex(where: { $0.id == id }) { return pool.remove(at: i) }
            if let appName, let title, let i = pool.firstIndex(where: { $0.appName == appName && $0.title == title }) {
                return pool.remove(at: i)
            }
            return nil
        }

        func build(_ node: TreeSnapshot.Node) -> Con? {
            guard let layout = node.layout else {
                guard let w = consume(node.windowID, node.appName, node.title) else { return nil }
                let con = Con(.window)
                con.windowID = w.id
                con.title = w.title
                con.percent = node.percent
                con.fullscreen = node.fullscreen
                restored += 1
                return con
            }
            let kids = node.children.compactMap(build)
            guard !kids.isEmpty else { return nil }
            let con = Con(.split)
            con.layout = layout
            con.lastSplit = layout.isTabLike ? .splitH : layout
            con.percent = node.percent
            for k in kids { con.attach(k) }
            con.fixPercent()
            return con
        }

        func matchOutput(_ saved: TreeSnapshot.Output) -> Con? {
            if let exact = root.children.first(where: { $0.name == saved.name }) { return exact }
            let byPosition = numberedOutputs
            return byPosition.indices.contains(saved.number - 1) ? byPosition[saved.number - 1] : nil
        }

        for savedOut in snapshot.outputs {
            guard !pool.isEmpty else { break }
            guard let out = matchOutput(savedOut) else { continue }
            for savedWs in savedOut.workspaces {
                guard !pool.isEmpty else { break }
                let existed = workspace(named: savedWs.name) != nil
                let ws = workspace(named: savedWs.name) ?? createWorkspace(savedWs.name, on: out)
                var gained = false
                for node in savedWs.nodes {
                    if let con = build(node) { ws.attach(con); gained = true }
                }
                for f in savedWs.floating {
                    guard let w = consume(f.windowID, f.appName, f.title) else { continue }
                    let con = Con(.window)
                    con.windowID = w.id
                    con.title = w.title
                    con.isFloating = true
                    con.rect = f.rect
                    ws.attach(con)
                    restored += 1
                    gained = true
                }
                if gained {
                    if !existed { ws.layout = savedWs.layout; ws.lastSplit = savedWs.layout.isTabLike ? .splitH : savedWs.layout }
                    ws.fixPercent()
                } else if !existed {
                    ws.detach()   // nothing from this saved workspace was actually missing: undo the speculative create
                }
            }
        }
        return restored
    }
}
