import AppKit

/// The card under the sidebar that shows a widget another program offered (`widget.offer`): its name, the team that
/// signed it (never a name the offering program gives itself), and Install / No. One offer at a time, oldest first.
final class OfferView: NSView {
    struct Item: Equatable {
        var id: String
        var displayName: String
        var version: String?
        var team: String
        /// The certificate's name with the team id, "Name (TEAMID)".
        var signer: String
        var teamTrusted: Bool
        var isUpdate: Bool
    }

    private(set) var items: [Item] = []
    private let header = NSTextField(labelWithString: "WIDGET OFFERED")
    private let counter = NSTextField(labelWithString: "")
    private let title = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let install = NSButton(title: "Install", target: nil, action: nil)
    private let no = NSButton(title: "No", target: nil, action: nil)
    /// The person's answer for an offer: true for Install.
    var onAnswer: ((String, Bool) -> Void)?
    override var isFlipped: Bool { true }

    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let noteFont = NSFont.systemFont(ofSize: 11)

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        header.font = .systemFont(ofSize: 10, weight: .bold)
        header.textColor = NSColor(white: 1, alpha: 0.45)
        counter.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        counter.textColor = NSColor(white: 1, alpha: 0.35)
        counter.alignment = .right
        title.font = Self.titleFont
        title.textColor = NSColor(white: 1, alpha: 0.9)
        note.font = Self.noteFont
        note.textColor = NSColor(white: 1, alpha: 0.55)
        for b in [install, no] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.target = self
        }
        install.action = #selector(installClicked)
        install.keyEquivalent = ""
        no.action = #selector(noClicked)
        for v in [header, counter, title, note, install, no] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ items: [Item]) {
        self.items = items
        guard let o = items.first else { return }
        title.stringValue = o.displayName + (o.version.map { " " + $0 } ?? "")
        note.stringValue = Self.note(o)
        counter.stringValue = items.count > 1 ? "1 / \(items.count)" : ""
        install.toolTip = o.teamTrusted ? "Install \(o.displayName)"
            : "Install \(o.displayName), then allow it in Settings ▸ Widgets"
        needsLayout = true
    }

    static func note(_ o: Item) -> String {
        let what = o.isUpdate ? "A program offers an update of this widget" : "A program offers this widget"
        let trust = o.teamTrusted ? "" : " Install opens Settings ▸ Widgets, where you allow it."
        return "\(what), signed by \(o.signer).\(trust)"
    }

    @objc private func installClicked() { if let o = items.first { onAnswer?(o.id, true) } }
    @objc private func noClicked() { if let o = items.first { onAnswer?(o.id, false) } }

    private static let measure = NSTextField(wrappingLabelWithString: "")
    private static func textHeight(_ s: String, _ font: NSFont, width: CGFloat) -> CGFloat {
        measure.font = font
        measure.stringValue = s
        return ceil(measure.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height)
    }

    func height(forWidth w: CGFloat) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        let tw = w - 24
        return 30 + Self.textHeight(title.stringValue, Self.titleFont, width: tw) + 4
            + Self.textHeight(note.stringValue, Self.noteFont, width: tw) + 10 + 22 + 12
    }

    override func layout() {
        super.layout()
        let w = bounds.width, tw = w - 24
        header.frame = NSRect(x: 12, y: 10, width: 140, height: 14)
        counter.frame = NSRect(x: w - 60, y: 10, width: 48, height: 14)
        let th = Self.textHeight(title.stringValue, Self.titleFont, width: tw)
        title.preferredMaxLayoutWidth = tw
        title.frame = NSRect(x: 12, y: 30, width: tw, height: th)
        let nh = Self.textHeight(note.stringValue, Self.noteFont, width: tw)
        note.preferredMaxLayoutWidth = tw
        note.frame = NSRect(x: 12, y: 30 + th + 4, width: tw, height: nh)
        let by = 30 + th + 4 + nh + 10
        install.sizeToFit()
        no.sizeToFit()
        install.frame = NSRect(x: w - 12 - install.frame.width, y: by, width: install.frame.width, height: 22)
        no.frame = NSRect(x: install.frame.minX - 6 - no.frame.width, y: by, width: no.frame.width, height: 22)
    }
}
