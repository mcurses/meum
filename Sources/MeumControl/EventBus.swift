// Ordered event stream with a ring buffer. Every consumer (socket subscribers, in-process widgets) uses it.
import Foundation

/// Matches event types: exact ("tab.added"), prefix wildcard ("tab.*" or "*"). An empty filter matches all.
public struct EventFilter: Sendable, Equatable {
    public var patterns: [String]
    public init(patterns: [String] = []) { self.patterns = patterns }

    public func matches(_ type: String) -> Bool {
        if patterns.isEmpty { return true }
        for p in patterns {
            if p == "*" || p == type { return true }
            if p.hasSuffix("*"), type.hasPrefix(String(p.dropLast())) { return true }
        }
        return false
    }
}

public struct SubscribeInfo: Sendable, Equatable {
    /// Highest seq published when the subscription started.
    public var seq: Int
    /// True when the requested `after` could not be honoured fully: events were dropped from the ring
    /// buffer, or `after` was from a previous run (higher than the current seq). The backlog replay then
    /// starts at the oldest event still held.
    public var gap: Bool
    /// Number of backlog events that will be replayed before live ones.
    public var replayed: Int
}

public final class EventBus: @unchecked Sendable {
    public final class Subscription: @unchecked Sendable {
        fileprivate let bus: EventBus
        fileprivate let id: Int
        fileprivate let queue: DispatchQueue
        fileprivate let filter: EventFilter
        fileprivate let deliver: @Sendable (Event) -> Void
        fileprivate var cancelled = false   // guarded by bus.lock

        fileprivate init(bus: EventBus, id: Int, filter: EventFilter, deliver: @escaping @Sendable (Event) -> Void) {
            self.bus = bus
            self.id = id
            self.filter = filter
            self.deliver = deliver
            self.queue = DispatchQueue(label: "meum.eventbus.sub.\(id)")
        }

        public func cancel() { bus.cancel(self) }
    }

    public let capacity: Int
    private let lock = NSLock()
    private var ring: [Event] = []
    private var seq = 0
    private var nextSubID = 1
    private var subs: [Int: Subscription] = [:]

    public init(capacity: Int = 1024) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var lastSeq: Int { lock.lock(); defer { lock.unlock() }; return seq }

    /// Appends an event and delivers it to every subscription, in order, on each subscription's own queue.
    @discardableResult
    public func publish(_ type: String, _ data: JSON = .null) -> Event {
        lock.lock()
        seq += 1
        let e = Event(seq: seq, type: type, data: data)
        ring.append(e)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        for s in subs.values where s.filter.matches(type) {
            s.queue.async { [weak s] in
                guard let s else { return }
                if s.isCancelled { return }
                s.deliver(e)
            }
        }
        lock.unlock()
        return e
    }

    /// Snapshot of the retained events with seq > `after` (all retained events when nil).
    public func backlog(after: Int?, filter: EventFilter = EventFilter()) -> (events: [Event], gap: Bool) {
        lock.lock(); defer { lock.unlock() }
        return backlogLocked(after: after, filter: filter)
    }

    private func backlogLocked(after: Int?, filter: EventFilter) -> (events: [Event], gap: Bool) {
        guard let after else { return ([], false) }
        if after > seq { return (ring.filter { filter.matches($0.type) }, true) }
        let oldest = ring.first?.seq ?? (seq + 1)
        let gap = oldest > after + 1
        return (ring.filter { $0.seq > after && filter.matches($0.type) }, gap)
    }

    /// Registers a subscription. `onStart` runs first on the subscription's queue (the server uses it to
    /// write the subscribe response), then the backlog since `after` is replayed, then live events follow,
    /// with no gap and no duplicate in between. With `after == nil` only live events are delivered.
    public func subscribe(after: Int?, filter: EventFilter = EventFilter(),
                          onStart: (@Sendable (SubscribeInfo) -> Void)? = nil,
                          deliver: @escaping @Sendable (Event) -> Void) -> Subscription {
        lock.lock()
        defer { lock.unlock() }
        let (events, gap) = backlogLocked(after: after, filter: filter)
        let sub = Subscription(bus: self, id: nextSubID, filter: filter, deliver: deliver)
        nextSubID += 1
        let info = SubscribeInfo(seq: seq, gap: gap, replayed: events.count)
        if let onStart { sub.queue.async { onStart(info) } }
        for e in events {
            sub.queue.async { [weak sub] in
                guard let sub else { return }
                if sub.isCancelled { return }
                sub.deliver(e)
            }
        }
        subs[sub.id] = sub
        return sub
    }

    /// In-process convenience: live events only, delivered on a private queue.
    public func addObserver(filter: EventFilter = EventFilter(),
                            _ handler: @escaping @Sendable (Event) -> Void) -> Subscription {
        subscribe(after: nil, filter: filter, deliver: handler)
    }

    fileprivate func cancel(_ s: Subscription) {
        lock.lock()
        s.cancelled = true
        subs[s.id] = nil
        lock.unlock()
    }

    fileprivate func isCancelled(_ s: Subscription) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return s.cancelled
    }

    public var subscriberCount: Int { lock.lock(); defer { lock.unlock() }; return subs.count }
}

private extension EventBus.Subscription {
    var isCancelled: Bool { bus.isCancelled(self) }
}
