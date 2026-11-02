// Minimal line diff (LCS) printed in unified style. Settings files are a few hundred lines at most.
import Foundation

public enum TextDiff {
    public static func unified(old: String, new: String, oldLabel: String, newLabel: String, context: Int = 3) -> String {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        if a == b { return "" }

        // LCS table.
        let n = a.count, m = b.count
        var t = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    t[i][j] = a[i] == b[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
                }
            }
        }
        // Edit script: (op, line)
        var ops: [(Character, String)] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] { ops.append((" ", a[i])); i += 1; j += 1 }
            else if i < n, j == m || t[i + 1][j] >= t[i][j + 1] { ops.append(("-", a[i])); i += 1 }
            else { ops.append(("+", b[j])); j += 1 }
        }

        // Group into hunks.
        var out = "--- \(oldLabel)\n+++ \(newLabel)\n"
        let changeIdx = ops.indices.filter { ops[$0].0 != " " }
        guard !changeIdx.isEmpty else { return "" }
        var hunks: [(Int, Int)] = []
        var start = max(0, changeIdx[0] - context), end = min(ops.count, changeIdx[0] + context + 1)
        for c in changeIdx.dropFirst() {
            if c - context <= end { end = min(ops.count, c + context + 1) }
            else { hunks.append((start, end)); start = max(0, c - context); end = min(ops.count, c + context + 1) }
        }
        hunks.append((start, end))

        for (s, e) in hunks {
            var oldStart = 1, newStart = 1
            for k in 0..<s { if ops[k].0 != "+" { oldStart += 1 }; if ops[k].0 != "-" { newStart += 1 } }
            let slice = ops[s..<e]
            let oldCount = slice.filter { $0.0 != "+" }.count
            let newCount = slice.filter { $0.0 != "-" }.count
            out += "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n"
            for (op, line) in slice { out += "\(op)\(line)\n" }
        }
        return out
    }
}
