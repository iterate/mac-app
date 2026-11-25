import Foundation

/// An event of the log by its offset in the context.
public protocol OffsetEvent: Sendable {
    var offset: Int { get }
}

/// THE ACTIVITY WINDOW'S HOLD ON THE DEVICE'S CONTEXT: at most `most` events, the newest first,
/// each once. It never holds the whole context (key events are many): the bridge says the newest
/// page when the window opens, the new events as they come, and an older page when the person
/// scrolls to the end of the list (`askOlder`), until the window holds `most`. A new event over
/// the bound pushes the oldest out.
public struct EventWindow<Event: OffsetEvent>: Sendable {
    public static var most: Int { 500 }

    /// The newest first.
    public private(set) var events: [Event] = []
    /// The context has older events than the window holds.
    public private(set) var hasOlder = false
    /// The first page came: the window shows the context, not a wait.
    public private(set) var isRead = false
    /// The offset the next older page is read below.
    private var before: Int?
    /// An older page was asked for and has not come.
    private var isAsking = false
    private var offsets: Set<Int> = []

    public init() {}

    /// The window holds as many events as it may: it reads no older page.
    public var isFull: Bool { events.count >= Self.most }

    /// A new connection or another context: the window is empty until its first page.
    public mutating func reset() {
        self = Self()
    }

    /// A new event, as the subscription brings it. False when the window had it.
    @discardableResult
    public mutating func take(_ event: Event) -> Bool {
        guard offsets.insert(event.offset).inserted else { return false }
        let index = events.firstIndex { $0.offset < event.offset } ?? events.endIndex
        events.insert(event, at: index)
        bound()
        return true
    }

    /// A page read backwards, the newest first; `before` is where the next one starts, `more`
    /// whether the context goes on below it.
    public mutating func take(page: [Event], before: Int, more: Bool) {
        isAsking = false
        isRead = true
        for event in page where offsets.insert(event.offset).inserted {
            // a page is older than what the window holds, but a new event may have come between
            if let last = events.last, last.offset < event.offset {
                let index = events.firstIndex { $0.offset < event.offset } ?? events.endIndex
                events.insert(event, at: index)
            } else {
                events.append(event)
            }
        }
        self.before = before
        hasOlder = more
        bound()
    }

    /// The offset to read an older page below, when one may be read now; nil while a page is on
    /// its way, when the window is full, or at the start of the context. It marks the page as
    /// asked for.
    public mutating func askOlder() -> Int? {
        guard isRead, !isAsking, hasOlder, !isFull, let before else { return nil }
        isAsking = true
        return before
    }

    /// Changes the events held in place: their order and offsets stay.
    public mutating func update(_ change: (inout Event) -> Void) {
        for index in events.indices {
            let offset = events[index].offset
            change(&events[index])
            precondition(events[index].offset == offset, "an update keeps the offset")
        }
    }

    /// The read failed: the next scroll to the end asks again.
    public mutating func failed() {
        isAsking = false
    }

    private mutating func bound() {
        guard events.count > Self.most else { return }
        for event in events[Self.most...] { offsets.remove(event.offset) }
        events.removeLast(events.count - Self.most)
        hasOlder = true
        before = events.last?.offset
    }
}
