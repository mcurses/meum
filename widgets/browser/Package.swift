// swift-tools-version: 6.0
// A browser as a meum widget: a WKWebView with a slim bar, meant for widget tabs next to the terminals (e.g. a
// dev server's page). Not part of meum: a separate widget, built and installed with
//   scripts/build-widget.sh widgets/browser BrowserWidget io.github.mcurses.meum.browser Browser tile
import PackageDescription

let package = Package(
    name: "BrowserWidget",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BrowserWidget", type: .dynamic, targets: ["BrowserWidget"])],
    dependencies: [.package(path: "../..")],
    targets: [
        .target(name: "BrowserWidget", dependencies: [.product(name: "MeumKit", package: "meum")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
