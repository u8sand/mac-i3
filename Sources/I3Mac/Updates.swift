// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mac-i3 contributors

import AppKit
import I3Core

/// "Check for Updates": asks GitHub for the latest published release and compares it with this build. Nothing is
/// downloaded or installed automatically; a newer release is offered as a link to its disk image.
public enum Updates {
    public struct Release {
        public let version: Version
        public let tag: String
        public let page: URL
        /// The disk image attached to the release, if any.
        public let dmg: URL?
    }

    static let latestURL = URL(string: "https://api.github.com/repos/u8sand/mac-i3/releases/latest")!

    /// The running version, or nil for a development build (not run from a packaged `.app`).
    public static var current: Version? {
        guard AppInfo.isBundled else { return nil }
        return (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(Version.init)
    }

    /// Fetch the latest release. Calls back on the main queue.
    public static func latest(_ done: @escaping (Result<Release, Error>) -> Void) {
        var req = URLRequest(url: latestURL, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("mac-i3", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, response, error in
            let result: Result<Release, Error> = Result {
                if let error { throw error }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data else { throw UpdateError("GitHub answered with status \(status)") }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String, let version = Version(tag),
                      let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
                    throw UpdateError("unexpected answer from GitHub")
                }
                let assets = json["assets"] as? [[String: Any]] ?? []
                let dmg = assets.compactMap { $0["browser_download_url"] as? String }
                    .first { $0.hasSuffix(".dmg") }.flatMap(URL.init(string:))
                return Release(version: version, tag: tag, page: page, dmg: dmg)
            }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }

    struct UpdateError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    /// The menu item: check, then say what was found.
    static func checkInteractively() {
        latest { result in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            switch result {
            case .failure(let e):
                alert.messageText = "Could not check for updates"
                alert.informativeText = e.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            case .success(let r):
                if let cur = current, !(cur < r.version) {
                    alert.messageText = "mac-i3 is up to date"
                    alert.informativeText = "You have version \(cur), the latest release."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }
                alert.messageText = current == nil ? "Latest release: mac-i3 \(r.version)" : "mac-i3 \(r.version) is available"
                alert.informativeText = current.map { "You have version \($0)." }
                    ?? "This is a development build, so it cannot tell whether it is older."
                alert.addButton(withTitle: r.dmg == nil ? "View Release" : "Download")
                alert.addButton(withTitle: "Release Notes")
                alert.addButton(withTitle: "Later")
                switch alert.runModal() {
                case .alertFirstButtonReturn: NSWorkspace.shared.open(r.dmg ?? r.page)
                case .alertSecondButtonReturn: NSWorkspace.shared.open(r.page)
                default: break
                }
            }
        }
    }
}
