// Go to Workspace (⌘P): what the switcher lists for a query.
//
// Workspaces match on their name, labels, group, folder and metadata values; tabs on their title, folder, Claude
// session name and labels. A match is fuzzy: the query's characters in order, not necessarily next to each other
// ("mm" finds "meum-main"), case- and accent-blind. Spaces split the query into words that must all match.
// Workspaces come before tabs. With an empty query the list is every workspace, the one used before this one first
// (Enter goes back, like ⌘Tab), then the others in sidebar order.

import Foundation

public enum WorkspaceSearch {
    public enum Target: Equatable, Hashable, Sendable {
        case workspace(UUID)
        case tab(workspace: UUID, tab: UUID)

        public var workspaceID: UUID {
            switch self {
            case .workspace(let w), .tab(let w, _): return w
            }
        }
    }

    public struct Hit: Equatable, Sendable {
        public var target: Target
        public var title: String
        /// Where it is or what else matched: a workspace's folder or group, a tab's workspace.
        public var subtitle: String
        /// Offsets of the matched characters in `title` (Character offsets), for highlighting.
        public var titleMatches: [Int]
        public var score: Int
    }

    /// At most this many tab rows (workspaces are all listed).
    public static let maxTabs = 12

    /// - Parameters:
    ///   - recent: workspace ids, most recently left first (the selected one may be in it; it is put last).
    ///   - home: shown as `~` in folders.
    public static func results(_ state: AppState, query: String, recent: [UUID] = [], home: String = NSHomeDirectory()) -> [Hit] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let groups = Dictionary(uniqueKeysWithValues: state.groups.map { ($0.id, $0.name) })
        let order = sidebarOrder(state)

        if words.isEmpty {
            let sel = state.selectedWorkspaceID
            var ids = recent.filter { id in id != sel && state.workspace(id) != nil }
            for w in state.workspaces where !ids.contains(w.id) && w.id != sel { ids.append(w.id) }
            if let sel, state.workspace(sel) != nil { ids.append(sel) }
            return ids.compactMap { id in
                state.workspace(id).map { ws in
                    Hit(target: .workspace(ws.id), title: ws.name, subtitle: workspaceSubtitle(ws, groups, home),
                        titleMatches: [], score: 0)
                }
            }
        }

        var wsHits: [(Hit, Int)] = []
        for ws in state.workspaces {
            let group = ws.group.flatMap { groups[$0] }
            let shown = ws.focusedCard?.selectedTab.cwd   // the folder its sidebar row shows
            let others = (ws.labels ?? []) + [group, folder(ws.cwd, home), folder(shown, home)].compactMap { $0 }
                + (ws.metadata.map { Array($0.values) } ?? [])
            guard let (score, marks) = match(words, title: ws.name, others: others) else { continue }
            let rank = (recent.firstIndex(of: ws.id) ?? recent.count) // ties: the recently used first
            wsHits.append((Hit(target: .workspace(ws.id), title: ws.name, subtitle: workspaceSubtitle(ws, groups, home),
                               titleMatches: marks, score: score), rank))
        }
        wsHits.sort { a, b in
            if a.0.score != b.0.score { return a.0.score > b.0.score }
            if a.1 != b.1 { return a.1 < b.1 }
            return (order[a.0.target.workspaceID] ?? 0) < (order[b.0.target.workspaceID] ?? 0)
        }

        var tabHits: [Hit] = []
        for ws in state.workspaces {
            for tab in ws.allTabs {
                let title = tabTitle(tab, home: home)
                let others = (tab.agent?.labels ?? []) + [tab.agent?.name, folder(tab.cwd, home)].compactMap { $0 }
                // tabs are many and their titles alike (user@host:~): letters scattered through one don't count
                guard let (score, marks) = match(words, title: title, others: others, strict: true) else { continue }
                // a tab gets a row only when it matches by itself, not through its workspace's name
                let sub = [tab.agent?.name, ws.name, folder(tab.cwd, home)].compactMap { $0 }.filter { !$0.isEmpty && $0 != title }
                tabHits.append(Hit(target: .tab(workspace: ws.id, tab: tab.id), title: title,
                                   subtitle: sub.joined(separator: " · "),
                                   titleMatches: marks, score: score))
            }
        }
        tabHits.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return (order[a.target.workspaceID] ?? 0) < (order[b.target.workspaceID] ?? 0)
        }
        return wsHits.map(\.0) + tabHits.prefix(maxTabs)
    }

    // MARK: matching

    /// Every word must match the title or one of the other fields. The score sums the words' best scores; a word
    /// matched in the title counts more and its characters are marked.
    /// `strict`: only runs of the word or its initials count, not letters scattered through a field.
    static func match(_ words: [String], title: String, others: [String], strict: Bool = false) -> (Int, [Int])? {
        let fuzzy = { (w: String, t: String) in Self.fuzzy(w, in: t, strict: strict) }
        var total = 0
        var marks: Set<Int> = []
        for w in words {
            var best: Int?
            if let (s, m) = fuzzy(w, title) {
                best = s * 2
                marks.formUnion(m)
            }
            for o in others {
                if let (s, _) = fuzzy(w, o), s > (best ?? Int.min) { best = s }
            }
            guard let b = best else { return nil }
            total += b
        }
        return (total, marks.sorted())
    }

    /// A fuzzy match of `query` in `text`: its characters in order. The score favours a match at the start, at word
    /// starts and in runs; nil when it does not match. Returns the matched Character offsets.
    public static func fuzzy(_ query: String, in text: String, strict: Bool = false) -> (Int, [Int])? {
        let q = Array(fold(query))
        let t = Array(fold(text))
        guard !q.isEmpty, q.count <= t.count else { return q.isEmpty ? (0, []) : nil }
        // a contiguous run wins over a scattered one: try the substring first
        if let r = fold(text).range(of: fold(query)) {
            let start = fold(text).distance(from: fold(text).startIndex, to: r.lowerBound)
            let atWord = start == 0 || isBoundary(t, start)
            // a run at a word start beats any scattered match, also initials; a run inside a word does not
            let s = 100 + q.count * 10 + (start == 0 ? 60 : atWord ? 40 : 0) + (atWord ? q.count * 20 + 60 : 0)
                - min(start, 20) - (t.count - q.count) / 4
            return (s, Array(start..<(start + q.count)))
        }
        // each character goes to the next word start that still leaves room for the rest, else the next occurrence
        func fits(_ from: Int, _ qi: Int) -> Bool {
            var k = qi
            for i in from..<t.count where k < q.count && t[i] == q[k] { k += 1 }
            return k == q.count
        }
        var score = 0, i = 0, last = -2
        var marks: [Int] = []
        for qi in 0..<q.count {
            guard let next = (i..<t.count).first(where: { t[$0] == q[qi] }) else { return nil }
            var pick = next
            if next != last + 1, !(next == 0 || isBoundary(t, next)),
               let w = ((next + 1)..<t.count).first(where: { t[$0] == q[qi] && isBoundary(t, $0) }), fits(w + 1, qi + 1) {
                pick = w
            }
            score += 10
            if pick == last + 1 { score += 15 }
            if pick == 0 { score += 30 } else if isBoundary(t, pick) { score += 20 }
            marks.append(pick)
            last = pick
            i = pick + 1
        }
        // every character at a word start ("mm" in "meum-main"): an abbreviation, worth more than letters inside a word
        let initials = q.count > 1 && marks.allSatisfy { $0 == 0 || isBoundary(t, $0) } ? 60 : 0
        if strict && initials == 0 { return nil }
        return (score + initials - (marks.last! - marks.first! - q.count + 1) - t.count / 4, marks)
    }

    static func isBoundary(_ t: [Character], _ i: Int) -> Bool {
        let p = t[i - 1]
        return !(p.isLetter || p.isNumber) || (p.isLowercase && t[i].isUppercase)
    }

    /// Lowercased without accents, one Character per Character of the original (so offsets carry over).
    static func fold(_ s: String) -> String {
        String(s.map { c -> Character in
            let f = String(c).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return f.count == 1 ? f.first! : c
        })
    }

    // MARK: presentation

    static func sidebarOrder(_ state: AppState) -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: state.workspaces.enumerated().map { ($1.id, $0) })
    }

    static func folder(_ path: String?, _ home: String) -> String? {
        guard let p = path, !p.isEmpty else { return nil }
        if p == home { return "~" }
        return p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }

    static func workspaceSubtitle(_ ws: Workspace, _ groups: [UUID: String], _ home: String) -> String {
        let dir = folder(ws.focusedCard?.selectedTab.cwd ?? ws.cwd, home)
        let group = ws.group.flatMap { groups[$0] }
        return [group, dir].compactMap { $0 }.joined(separator: " · ")
    }

    /// A tab's name as its strip shows it: the terminal's title, else its folder's name, else "shell".
    public static func tabTitle(_ tab: Tab, home: String = NSHomeDirectory()) -> String {
        if let t = tab.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        if let cwd = tab.cwd, !cwd.isEmpty { return cwd == home ? "~" : (cwd as NSString).lastPathComponent }
        return "shell"
    }
}
