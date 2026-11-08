import Foundation

/// "Go to Next Waiting Session": the next tab, in sidebar order after the current one and wrapping around, where
/// Claude waits for the user; when none waits, the next one with a finished, unread session.
public enum NextWaiting {
    public static func pick(order: [UUID], current: UUID?, waiting: Set<UUID>, unread: Set<UUID>) -> UUID? {
        guard !order.isEmpty else { return nil }
        let start = current.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        let rotated = Array(order[start...] + order[..<start])
        return rotated.first(where: waiting.contains) ?? rotated.first(where: unread.contains)
    }
}
