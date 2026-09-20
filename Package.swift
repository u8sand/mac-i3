// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "mac-i3",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "mac-i3", targets: ["mac-i3"]),
    ],
    targets: [
        // Pure i3 tree/layout/command logic. No AppKit, fully unit-testable.
        .target(name: "I3Core"),
        // i3 config file parsing (bindsym, mode, set, ...).
        .target(name: "I3Config"),
        // macOS glue: Accessibility API, event tap, overlays, displays.
        .target(name: "I3Mac", dependencies: ["I3Core", "I3Config"]),
        .executableTarget(name: "mac-i3", dependencies: ["I3Core", "I3Config", "I3Mac"]),
        .testTarget(name: "I3CoreTests", dependencies: ["I3Core"]),
        .testTarget(name: "I3ConfigTests", dependencies: ["I3Config"]),
    ],
    swiftLanguageModes: [.v5]
)
