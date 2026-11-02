import AppKit
import MeumKit
import SwiftUI

@_cdecl("meum_widget_main")
public func meumWidgetMain() -> UnsafeMutableRawPointer {
    MeumWidgetRegistration(manifest: .init(id: "io.github.mcurses.meum.hello", displayName: "Hello", version: "1",
                                           uses: ["notify"])) { host in
        HelloWidget(host: host)
    }.export()
}

@MainActor
final class HelloModel: ObservableObject {
    @Published var clicks = 0
    @Published var name = ""
    @Published var tall = false
    @Published var visible = true
    @Published var collapsed = false
    @Published var appearance = MeumWidgetAppearance()
}

@MainActor
final class HelloWidget: MeumWidget {
    let host: MeumWidgetHost
    let model = HelloModel()
    lazy var view: NSView = {
        let v = NSHostingView(rootView: HelloView(model: model, host: host))
        v.sizingOptions = []
        return v
    }()

    init(host: MeumWidgetHost) {
        self.host = host
        model.appearance = host.appearance
        host.setPreferredHeight(90)
    }

    func appearanceDidChange(_ a: MeumWidgetAppearance) { model.appearance = a }
    func visibilityDidChange(_ v: MeumWidgetVisibility) { model.visible = v.isVisible }

    // the collapsed sidebar: just the counter, in a short card
    var supportsCollapsedSidebar: Bool { true }
    func sidebarCollapsedDidChange(_ collapsed: Bool) {
        model.collapsed = collapsed
        host.setPreferredHeight(collapsed ? 48 : (model.tall ? 180 : 90))
    }
}

struct HelloView: View {
    @ObservedObject var model: HelloModel
    let host: MeumWidgetHost

    var body: some View {
        if model.collapsed {
            Button("\(model.clicks)") { model.clicks += 1 }
                .buttonStyle(.plain)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .help("hello: clicked \(model.clicks)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.colorScheme, model.appearance.scheme == .dark ? .dark : .light)
        } else {
            expanded
        }
    }

    var expanded: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("hello from a widget").font(.caption.weight(.semibold))
            HStack {
                Button("clicked \(model.clicks)") { model.clicks += 1 }
                Button(model.tall ? "shorter" : "taller") {
                    model.tall.toggle()
                    host.setPreferredHeight(model.tall ? 180 : 90)
                }
            }
            TextField("type here", text: $model.name).textFieldStyle(.roundedBorder)
            if model.tall { Text("name: \(model.name)  visible: \(model.visible ? "yes" : "no")").font(.caption2) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, model.appearance.scheme == .dark ? .dark : .light)
        .contextMenu { Button("Notify") { host.notify(title: "Hello widget", body: "clicked \(model.clicks)", workspace: nil) } }
    }
}
