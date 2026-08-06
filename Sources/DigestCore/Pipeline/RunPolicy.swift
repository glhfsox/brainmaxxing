import Foundation

public struct RunDecision: Sendable, Equatable {
    public let run: Bool
    public let reason: String
    public init(run: Bool, reason: String) {
        self.run = run
        self.reason = reason
    }
}

/// Decides whether a scheduled (`--if-due`) run should start. Implemented for real by the scheduler agent.
public protocol RunPolicy: Sendable {
    func shouldRun(now: Date, lastSuccess: Date?) async -> RunDecision
}

// AlwaysRunPolicy is kept for tests; the CLI uses DefaultRunPolicy (window + idle gating) in Scheduling/.
public struct AlwaysRunPolicy: RunPolicy {
    public init() {}
    public func shouldRun(now: Date, lastSuccess: Date?) async -> RunDecision {
        RunDecision(run: true, reason: "no run policy: always due")
    }
}
