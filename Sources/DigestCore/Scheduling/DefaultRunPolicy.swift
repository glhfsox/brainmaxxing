import Foundation

/// "Is the user here" signals. Real: `IOKitIdleSource`; tests: a fake.
public protocol IdleSource: Sendable {
    /// Seconds since the last keyboard/mouse event (IOKit `HIDIdleTime`).
    func idleSeconds() async -> TimeInterval
    /// `CGDisplayIsAsleep(CGMainDisplayID())`.
    func displayAsleep() async -> Bool
}

/// The `--if-due` gate. Runs iff no complete run started today (local day), the local hour is inside
/// `[window_start, window_end)`, and the user is away (idle >= `idle_minutes` or display asleep).
/// Conditions are checked in that order; the reason names the first one that failed.
public struct DefaultRunPolicy: RunPolicy {
    let config: Config
    let idle: IdleSource
    let calendar: Calendar

    public init(config: Config, idle: IdleSource, calendar: Calendar = .current) {
        self.config = config
        self.idle = idle
        self.calendar = calendar
    }

    public func shouldRun(now: Date, lastSuccess: Date?) async -> RunDecision {
        let s = config.schedule
        if let last = lastSuccess, calendar.isDate(last, inSameDayAs: now) {
            return RunDecision(run: false, reason: "already ran today at \(hourMinute(last))")
        }
        let hour = calendar.component(.hour, from: now)
        guard hour >= s.windowStart, hour < s.windowEnd else {
            return RunDecision(run: false, reason: String(format: "outside the %02d:00-%02d:00 window", s.windowStart, s.windowEnd))
        }
        if await idle.displayAsleep() {
            return RunDecision(run: true, reason: "display asleep")
        }
        let idleSeconds = await idle.idleSeconds()
        let idleMinutes = Int(idleSeconds / 60)
        if idleSeconds >= TimeInterval(s.idleMinutes * 60) {
            return RunDecision(run: true, reason: "user idle \(idleMinutes) min")
        }
        return RunDecision(run: false, reason: "user active \(idleMinutes) min ago")
    }

    private func hourMinute(_ date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
