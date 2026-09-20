// swift-tools-version:6.0
//
// One executable, deliberately: Winbar.app/Contents/MacOS/Winbar is both the menu bar app and the
// `winbar` CLI (see main.swift). A second, lowercase `winbar` binary next to it would collide with
// `Winbar` on case-insensitive APFS.
//
// Tools 6.0 only so that `swiftLanguageModes` exists; the code itself is Swift 5 language mode, and
// nothing here needs Xcode — the Command Line Tools build it.

import PackageDescription

let package = Package(
    name: "Winbar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Winbar", targets: ["Winbar"]),
    ],
    targets: [
        .executableTarget(
            name: "Winbar",
            path: "Sources/Winbar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security"),
            ]
        ),
        // Pure-logic tests only (parsers, quoting, recommendations). Nothing in them may talk to UTM,
        // a VM, the keychain or TCC. Swift Testing, not XCTest, which the Command Line Tools lack
        // entirely. Even so `swift test` needs Xcode's toolchain: the Command Line Tools 6.3 ship a
        // Testing.framework SwiftPM doesn't find, and forcing the path fails on a missing
        // lib_TestingInterop.dylib. Only the tests are affected; the app builds with the CLT alone.
        .testTarget(
            name: "WinbarTests",
            dependencies: ["Winbar"],
            path: "Tests/WinbarTests",
            // The fixtures are read straight from the source tree with #filePath, not from a bundle:
            // a resource bundle would make `swift test` the only way to reach them, and these files
            // exist to be compared with the tools that made them (the answer-file renderer, hdiutil).
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
