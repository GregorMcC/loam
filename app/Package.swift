// swift-tools-version:6.2
// The Loam app: a macOS terminal on libghostty, and one front end to the Loam core.
import Foundation
import PackageDescription

// GhosttyKit comes from scripts/build-ghosttykit.sh, which links app/vendor/ to a
// per-commit cache. Without the link, the package still builds LoamKit and its
// tests. scripts/install.sh always builds the link first.
let ghosttyKitPath = "vendor/GhosttyKit.xcframework"
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let hasGhosttyKit = FileManager.default.fileExists(atPath: packageDir + "/" + ghosttyKitPath)

var targets: [Target] = [
    // Testable app code with no libghostty dependency: the core client,
    // the contract types, and the models.
    .target(name: "LoamKit"),
    .testTarget(name: "LoamKitTests", dependencies: ["LoamKit"]),
]

let ghosttyLinkerSettings: [LinkerSetting] = [
    .linkedFramework("AppKit"),
    .linkedFramework("Carbon"),
    .linkedFramework("CoreText"),
    .linkedFramework("IOSurface"),
    .linkedFramework("Metal"),
    .linkedFramework("QuartzCore"),
    .linkedLibrary("c++"),
]

if hasGhosttyKit {
    targets += [
        .binaryTarget(name: "GhosttyKit", path: ghosttyKitPath),
        // The pane's terminal surface on libghostty: input, clipboard, and the
        // safe close order.
        .target(
            name: "LoamTerminal",
            dependencies: ["LoamKit", "GhosttyKit"],
            linkerSettings: ghosttyLinkerSettings
        ),
        // The scripted driver: a test mode of the app (LOAM_DRIVER=<scenario>).
        .target(name: "LoamDriver", dependencies: ["LoamKit", "LoamTerminal", "GhosttyKit"]),
        .executableTarget(
            name: "Loam",
            dependencies: ["LoamKit", "LoamTerminal", "LoamDriver", "GhosttyKit"],
            linkerSettings: ghosttyLinkerSettings
        ),
        // Runs the built app in driver mode and checks its log.
        .testTarget(name: "LoamDriverTests", dependencies: ["Loam"]),
    ]
} else {
    targets.append(.executableTarget(name: "Loam", dependencies: ["LoamKit"]))
}

let package = Package(
    name: "Loam",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Loam", targets: ["Loam"]),
    ],
    targets: targets
)
