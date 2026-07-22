import Foundation

/// Spaces calls at least `minInterval` apart. Clock and sleep are injectable so tests don't wait.
public actor RateLimiter {
    private let minInterval: TimeInterval
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var nextSlot: Date?

    public init(
        minInterval: TimeInterval, clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.minInterval = minInterval
        self.clock = clock
        self.sleep = sleep
    }

    /// Waits until the next slot. The slot is reserved before sleeping, so concurrent callers queue up.
    public func wait() async throws {
        let now = clock()
        let slot = max(now, nextSlot ?? now)
        nextSlot = slot.addingTimeInterval(minInterval)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 { try await sleep(delay) }
    }
}
