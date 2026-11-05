import Foundation

/// Which links a click on a sidebar status entry opens. Any program in a tab can set a status entry
/// (`meum status set --url`), and the click is the user's, so the link's scheme decides: http and https open, a
/// scheme the user allowed before opens, any other asks first (meum remembers a yes in `statusLinkSchemes`, which
/// only Settings changes, never the socket).
public enum StatusLink {
    public static let alwaysOpen: Set<String> = ["http", "https"]

    public enum Decision: Equatable {
        case open
        /// Ask before opening; the scheme in lower case.
        case ask(String)
        case refuse
    }

    public static func decide(_ url: URL, allowed: [String]) -> Decision {
        guard let scheme = url.scheme?.lowercased(), isScheme(scheme) else { return .refuse }
        if alwaysOpen.contains(scheme) || allowed.contains(scheme) { return .open }
        return .ask(scheme)
    }

    /// A URL scheme as RFC 3986 spells it: a letter, then letters, digits, "+", "-" or ".".
    public static func isScheme(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, first.isASCII, CharacterSet.letters.contains(first) else { return false }
        return s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0)) }
    }
}
