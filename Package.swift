// swift-tools-version: 6.0
// Host-free parts of meum: the model (MeumCore), the control channel (MeumControl) and the `meum` CLI.
// The app itself (AppKit + libghostty) lives in App/ and is built by scripts/build-app.sh, so this
// package builds and tests with plain `swift build` / `swift test`, without Ghostty or Xcode.
import PackageDescription

let package = Package(
    name: "meum",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MeumCore", targets: ["MeumCore"]),
        .library(name: "MeumControl", targets: ["MeumControl"]),
        // Dynamic, so meum and every widget library share one copy at run time (Contents/Frameworks).
        .library(name: "MeumKit", type: .dynamic, targets: ["MeumKit"]),
        .executable(name: "meum", targets: ["meum"]),
    ],
    targets: [
        .target(name: "MeumCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "MeumControl", dependencies: ["MeumCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // Library evolution keeps widgets built against an older MeumKit loading after meum updates.
        .target(name: "MeumKit", swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-enable-library-evolution"])]),
        .executableTarget(name: "meum", dependencies: ["MeumControl"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MeumCoreTests", dependencies: ["MeumCore"]),
        .testTarget(name: "MeumControlTests", dependencies: ["MeumControl"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
