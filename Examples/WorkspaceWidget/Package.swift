// swift-tools-version: 6.0
// A workspace widget: shows the selected workspace and hides its card where there is nothing to show (a
// workspace in the home folder). Build and install it with
//   scripts/build-widget.sh Examples/WorkspaceWidget WorkspaceWidget io.github.mcurses.meum.workspace Workspace workspace
import PackageDescription

let package = Package(
    name: "WorkspaceWidget",
    platforms: [.macOS(.v14)],
    products: [.library(name: "WorkspaceWidget", type: .dynamic, targets: ["WorkspaceWidget"])],
    dependencies: [.package(path: "../..")],
    targets: [
        .target(name: "WorkspaceWidget", dependencies: [.product(name: "MeumKit", package: "meum")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
