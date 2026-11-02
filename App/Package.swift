// swift-tools-version: 6.0
// The meum app (AppKit + libghostty). Separate from the root package so `swift build` / `swift test` at the
// root never needs Ghostty or Xcode. Build it with scripts/build-app.sh, which also assembles build/meum.app.
// GhosttyKit comes from vendor/ghostty (scripts/setup.sh); it is linked as a static library via flags,
// because its xcframework ships a plain .a with a module map.
import Foundation
import PackageDescription

// absolute, because the compiler's working directory is not App/
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
let xcf = root + "/vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64"

let package = Package(
    name: "MeumApp",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "meum", path: "..")],
    targets: [
        .executableTarget(
            name: "MeumApp",
            dependencies: [.product(name: "MeumCore", package: "meum"), .product(name: "MeumControl", package: "meum"),
                           .product(name: "MeumKit", package: "meum")],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-I", xcf + "/Headers"]),
            ],
            linkerSettings: [
                .unsafeFlags([xcf + "/libghostty-internal.a", "-lc++"]),
                .linkedFramework("AppKit"), .linkedFramework("Metal"), .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"), .linkedFramework("CoreGraphics"), .linkedFramework("IOSurface"),
                .linkedFramework("Carbon"), .linkedFramework("CoreVideo"),
                .linkedFramework("UniformTypeIdentifiers"), .linkedFramework("GameController"),
            ]
        ),
    ]
)
