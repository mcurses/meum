// swift-tools-version: 6.0
// The smallest meum widget: a SwiftUI view in the card under the sidebar. Build and install it with
//   scripts/build-widget.sh Examples/HelloWidget HelloWidget
import PackageDescription

let package = Package(
    name: "HelloWidget",
    platforms: [.macOS(.v14)],
    products: [.library(name: "HelloWidget", type: .dynamic, targets: ["HelloWidget"])],
    dependencies: [.package(path: "../..")],
    targets: [
        .target(name: "HelloWidget", dependencies: [.product(name: "MeumKit", package: "meum")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
