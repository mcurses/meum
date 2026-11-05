import AppKit
import MeumKit
import WebKit

@_cdecl("meum_widget_main")
public func meumWidgetMain() -> UnsafeMutableRawPointer {
    MeumWidgetRegistration(manifest: .init(id: "io.github.mcurses.meum.browser", displayName: "Browser", version: "1",
                                           uses: ["messages", "configuration"])) { host in
        BrowserWidget(host: host)
    }.export()
}

/// A web page in a widget tab. Settings (saved with the tab): `{"url": "…"}`; the widget updates them as you
/// navigate, so the tab reopens on the same page.
///
/// Messages (`meum widget send`, the MCP tool `meum_widget_send`), each answered with the state below:
///   {"navigate": URL}  {"reload": true}  {"back": true}  {"forward": true}  {"state": true}
///   {"action": "screenshot"} -> {"png": base64}
/// State: {"url", "title", "loading", "errors": [the last console errors and uncaught exceptions]}.
/// Console errors are also published as `widget.event` {kind: "console", level, message}.
@MainActor
final class BrowserWidget: NSObject, MeumWidget, WKNavigationDelegate, WKScriptMessageHandler, NSTextFieldDelegate {
    let host: MeumWidgetHost
    let root = FlippedRoot()
    let web: WKWebView
    let bar = NSView()
    let field = NSTextField()
    let back = NSButton()
    let forward = NSButton()
    let reload = NSButton()
    private var errors: [String] = []
    private var observations: [NSKeyValueObservation] = []

    var view: NSView { root }

    static let barHeight: CGFloat = 30

    init(host: MeumWidgetHost) {
        self.host = host
        let config = WKWebViewConfiguration()
        // Say "Safari" like Safari does: without it sites (Google among them) take the web view for an unknown
        // browser and serve their old, basic pages.
        let safari = Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String
        let version = (safari ?? "26.0").split(separator: ".").prefix(2).joined(separator: ".")
        config.applicationNameForUserAgent = "Version/\(version) Safari/605.1.15"
        // console errors and uncaught exceptions come back to the widget
        let hook = """
        (function(){
          const post = (level, args) => { try { window.webkit.messageHandlers.meum.postMessage({level, message: args.map(a => {
            try { return typeof a === 'string' ? a : (a && a.stack) || JSON.stringify(a) } catch (e) { return String(a) } }).join(' ')}) } catch (e) {} };
          const orig = console.error.bind(console);
          console.error = (...a) => { post('error', a); orig(...a) };
          const warn = console.warn.bind(console);
          console.warn = (...a) => { post('warn', a); warn(...a) };
          window.addEventListener('error', e => post('error', [e.message + ' (' + e.filename + ':' + e.lineno + ')']));
          window.addEventListener('unhandledrejection', e => post('error', ['unhandled rejection: ' + (e.reason && e.reason.stack || e.reason)]));
        })();
        """
        config.userContentController.addUserScript(WKUserScript(source: hook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(WeakHandler(self), name: "meum")
        web.navigationDelegate = self
        web.isInspectable = true   // right-click > Inspect Element (Safari's Web Inspector)
        web.allowsBackForwardNavigationGestures = true
        build()
        observations = [
            web.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateBar() } },
            web.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateBar() } },
            web.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateBar() } },
            web.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.urlChanged() } },
        ]
        if let url = Self.configuredURL(host.configuration) { load(url) } else {
            web.loadHTMLString(Self.blank, baseURL: nil)
            DispatchQueue.main.async { [weak self] in self?.root.window?.makeFirstResponder(self?.field) }
        }
    }

    // MARK: layout

    private func build() {
        root.wantsLayer = true
        bar.frame = NSRect(x: 0, y: 0, width: 400, height: Self.barHeight)
        bar.autoresizingMask = [.width]
        for (b, symbol, action) in [(back, "chevron.left", #selector(goBack)), (forward, "chevron.right", #selector(goForward)),
                                    (reload, "arrow.clockwise", #selector(doReload))] {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            b.bezelStyle = .accessoryBarAction
            b.isBordered = false
            b.contentTintColor = NSColor(white: 1, alpha: 0.7)
            b.target = self
            b.action = action
            bar.addSubview(b)
        }
        field.placeholderString = "URL, or a port like :5173"
        field.font = .systemFont(ofSize: 12)
        field.focusRingType = .none
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        bar.addSubview(field)
        root.addSubview(bar)
        web.autoresizingMask = [.width, .height]
        root.addSubview(web)
        root.onLayout = { [weak self] in self?.layout() }
        updateBar()
    }

    private func layout() {
        let w = root.bounds.width, h = Self.barHeight
        bar.frame = NSRect(x: 0, y: 0, width: w, height: h)
        back.frame = NSRect(x: 6, y: 5, width: 22, height: 20)
        forward.frame = NSRect(x: 28, y: 5, width: 22, height: 20)
        reload.frame = NSRect(x: 50, y: 5, width: 22, height: 20)
        field.frame = NSRect(x: 78, y: 4, width: max(40, w - 86), height: 22)
        web.frame = NSRect(x: 0, y: h, width: w, height: max(0, root.bounds.height - h))
    }

    private func updateBar() {
        back.isEnabled = web.canGoBack
        forward.isEnabled = web.canGoForward
        reload.image = NSImage(systemSymbolName: web.isLoading ? "xmark" : "arrow.clockwise", accessibilityDescription: nil)
    }

    // MARK: navigation

    static func configuredURL(_ json: String?) -> URL? {
        guard let json, let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let s = d["url"] as? String else { return nil }
        return normalize(s)
    }

    /// "localhost:3000", ":5173", "example.com" or a full URL.
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix(":") { s = "http://localhost" + s }
        if !s.contains("://") {
            let local = s.hasPrefix("localhost") || s.hasPrefix("127.") || s.hasPrefix("[::1]")
            s = (local ? "http://" : "https://") + s
        }
        return URL(string: s)
    }

    func load(_ url: URL) {
        field.stringValue = url.absoluteString
        web.load(URLRequest(url: url))
    }

    @objc private func submit() {
        guard let url = Self.normalize(field.stringValue) else { return }
        load(url)
        root.window?.makeFirstResponder(web)
    }

    @objc private func goBack() { web.goBack() }
    @objc private func goForward() { web.goForward() }
    @objc private func doReload() { if web.isLoading { web.stopLoading() } else { web.reload() } }

    private func urlChanged() {
        guard let url = web.url, url.scheme == "http" || url.scheme == "https" || url.scheme == "file" else { return }
        if root.window?.firstResponder !== field.currentEditor() { field.stringValue = url.absoluteString }
        // the tab remembers the page
        let json = (try? JSONSerialization.data(withJSONObject: ["url": url.absoluteString], options: [.withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) }
        if json != host.configuration { host.setConfiguration(json) }
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated { errors = [] }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            let msg = "load failed: \(error.localizedDescription)"
            record("error", msg)
            webView.loadHTMLString(Self.page(title: "Could not load", body: msg), baseURL: nil)
        }
    }

    // MARK: console

    nonisolated func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let d = message.body as? [String: Any] else { return }
            record(d["level"] as? String ?? "error", d["message"] as? String ?? "")
        }
    }

    private func record(_ level: String, _ message: String) {
        errors.append("\(level): \(message)")
        if errors.count > 50 { errors.removeFirst(errors.count - 50) }
        if let d = try? JSONSerialization.data(withJSONObject: ["kind": "console", "level": level, "message": message]) {
            host.publish(String(decoding: d, as: UTF8.self))
        }
    }

    // MARK: MeumWidget

    func appearanceDidChange(_ appearance: MeumWidgetAppearance) {}

    func willUnload() {
        observations = []
        web.stopLoading()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "meum")
    }

    func receive(_ message: String, reply: @escaping @MainActor (String) -> Void) {
        guard let m = (try? JSONSerialization.jsonObject(with: Data(message.utf8))) as? [String: Any] else {
            reply(#"{"error": "expected a JSON object"}"#)
            return
        }
        if m["action"] as? String == "screenshot" {
            screenshot(reply)
            return
        }
        if let s = m["navigate"] as? String {
            guard let url = Self.normalize(s) else { reply(#"{"error": "not a URL"}"#); return }
            load(url)
        } else if m["reload"] != nil {
            web.reload()
        } else if m["back"] != nil {
            web.goBack()
        } else if m["forward"] != nil {
            web.goForward()
        } else if m["state"] == nil {
            reply(#"{"error": "unknown message; try navigate, reload, back, forward, state, or action: screenshot"}"#)
            return
        }
        // navigation answers once the page has settled (or after 10 s), so the state is useful
        let start = Date()
        func settle() {
            if self.web.isLoading, Date().timeIntervalSince(start) < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { settle() } }
                return
            }
            reply(self.stateJSON())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { MainActor.assumeIsolated { settle() } }
    }

    private func stateJSON() -> String {
        let d: [String: Any] = ["url": web.url?.absoluteString ?? NSNull(), "title": web.title ?? "",
                                "loading": web.isLoading, "errors": errors]
        return (try? JSONSerialization.data(withJSONObject: d, options: [.withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private func screenshot(_ reply: @escaping @MainActor (String) -> Void) {
        let cfg = WKSnapshotConfiguration()
        web.takeSnapshot(with: cfg) { image, error in
            MainActor.assumeIsolated {
                guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    reply(#"{"error": "snapshot failed: \#(error?.localizedDescription ?? "no image")"}"#)
                    return
                }
                reply(#"{"png": "\#(png.base64EncodedString())"}"#)
            }
        }
    }

    // MARK: pages

    static let blank = page(title: "Browser", body: "Type a URL above, or a port like :5173.")

    static func page(title: String, body: String) -> String {
        let esc = { (s: String) in s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        return """
        <html><body style="background:#16181d;color:#9aa0a6;font:13px -apple-system;display:flex;align-items:center;\
        justify-content:center;height:100vh;margin:0"><div style="text-align:center"><div style="font-weight:600;\
        color:#d0d4d9">\(esc(title))</div><div style="margin-top:6px">\(esc(body))</div></div></body></html>
        """
    }
}

/// A flipped view that reports layout, so the widget lays out its bar and page.
final class FlippedRoot: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        onLayout?()
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        onLayout?()
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(uc, didReceive: message)
    }
}
