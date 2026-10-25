// swift-tools-version: 6.0
// ShrikeKit — local Swift Package hosting Shrike's library modules.
// The Shrike.app target depends on this package so module boundaries stay strict.

import PackageDescription

let package = Package(
    name: "ShrikeKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ShrikeCore",      targets: ["ShrikeCore"]),
        .library(name: "ShrikeRendering", targets: ["ShrikeRendering"]),
        .library(name: "ShrikeUI",        targets: ["ShrikeUI"]),
        .library(name: "ShrikeEdit",      targets: ["ShrikeEdit"]),
        .library(name: "ShrikeIO",        targets: ["ShrikeIO"]),
    ],
    dependencies: [
        // GRDB powers the ratings/tags/recents store.
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.3"),
    ],
    targets: [
        // Core — pure-Swift utilities, no AppKit dependency where avoidable.
        .target(
            name: "ShrikeCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/ShrikeCore",
            swiftSettings: sharedSwiftSettings
        ),

        // Rendering — CAMetalLayer host, thumbnail cell view, color pipeline.
        // Depends on Core for signposts and preferences.
        .target(
            name: "ShrikeRendering",
            dependencies: ["ShrikeCore"],
            path: "Sources/ShrikeRendering",
            swiftSettings: sharedSwiftSettings
        ),

        // UI — AppKit windows (Viewer, Browser, Compare, Batch) + SwiftUI inspectors.
        // Depends on ShrikeEdit for the edit-mode shell.
        .target(
            name: "ShrikeUI",
            dependencies: ["ShrikeCore", "ShrikeRendering", "ShrikeEdit", "ShrikeIO"],
            path: "Sources/ShrikeUI",
            swiftSettings: sharedSwiftSettings + sizeOptimizedSettings
        ),

        // Edit — Crop, Resize, Rotate, ColorAdjust, Undo, lossless
        // orientation rotate. Depends on IO for BackupStore (backup before
        // any overwrite of a user file).
        .target(
            name: "ShrikeEdit",
            dependencies: ["ShrikeCore", "ShrikeIO"],
            path: "Sources/ShrikeEdit",
            swiftSettings: sharedSwiftSettings + sizeOptimizedSettings
        ),

        // IO — file operations, Finder tag bridging, external editor invocation.
        .target(
            name: "ShrikeIO",
            dependencies: ["ShrikeCore"],
            path: "Sources/ShrikeIO",
            swiftSettings: sharedSwiftSettings + sizeOptimizedSettings
        ),

        // Harness test target — proves the build/test plumbing works end to end.
        .testTarget(
            name: "ShrikeCoreTests",
            dependencies: ["ShrikeCore"],
            path: "Tests/ShrikeCoreTests",
            resources: [
                .process("Fixtures"),
            ],
            swiftSettings: sharedSwiftSettings
        ),

        // ShrikeRendering unit tests — pure transform math + texture-upload
        // regression coverage. Fixtures bundled for the upload tests, which
        // exercise the real CIContext + MTKTextureLoader path on hosts with
        // a Metal device (skipped on CI runners without one).
        .testTarget(
            name: "ShrikeRenderingTests",
            dependencies: ["ShrikeRendering", "ShrikeCore"],
            path: "Tests/ShrikeRenderingTests",
            resources: [
                .process("Fixtures"),
            ],
            swiftSettings: sharedSwiftSettings
        ),

        // ShrikeUI unit tests — ViewerKeyMap + NavigationController behaviour.
        .testTarget(
            name: "ShrikeUITests",
            dependencies: ["ShrikeUI"],
            path: "Tests/ShrikeUITests",
            swiftSettings: sharedSwiftSettings
        ),

        // ShrikeEdit unit tests — recipe/renderer/exporter + prefs-edit keys.
        // Fixtures from ShrikeCoreTests are not directly importable across
        // test targets under SwiftPM, so this target carries its own
        // minimal fixture set under Fixtures/.
        .testTarget(
            name: "ShrikeEditTests",
            dependencies: ["ShrikeEdit", "ShrikeCore", "ShrikeIO"],
            path: "Tests/ShrikeEditTests",
            resources: [
                .process("Fixtures"),
            ],
            swiftSettings: sharedSwiftSettings
        ),

        // ShrikeIO unit tests — BackupStore, FileOperations, FolderWatcher,
        // FinderTags, ExternalEditor. Temp directories only; never touches
        // real user folders.
        .testTarget(
            name: "ShrikeIOTests",
            dependencies: ["ShrikeIO", "ShrikeCore"],
            path: "Tests/ShrikeIOTests",
            swiftSettings: sharedSwiftSettings
        ),
    ]
)

// Shared Swift settings: Swift 6, strict concurrency, warnings-as-errors,
// ExistentialAny upcoming-feature. Matches the app-target settings.
var sharedSwiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("ExistentialAny"),
        .enableExperimentalFeature("StrictConcurrency"),
        .unsafeFlags(["-warnings-as-errors"], .when(configuration: .release)),
    ]
}

// Release-only -Osize for the UI-shaped modules (ShrikeUI, ShrikeEdit, ShrikeIO).
// Saves about 2 MB in the universal app. ShrikeCore (decode, thumbnails),
// ShrikeRendering (Metal) and GRDB stay on -O. Debug builds and `swift test`
// are not affected.
var sizeOptimizedSettings: [SwiftSetting] {
    [.unsafeFlags(["-Osize"], .when(configuration: .release))]
}
