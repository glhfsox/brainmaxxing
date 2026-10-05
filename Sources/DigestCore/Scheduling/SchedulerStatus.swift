import Foundation

/// What `digest-cli status` and the menu bar show (not `RunStatus`, which is the run-row status
/// enum).
public struct SchedulerStatus: Sendable, Equatable {
    public var lastRun: RunRecord?
    public var lastCompleteRunStart: Date?
    /// `YYYY-MM-DD` local date of the newest stored digest.
    public var latestDigestDate: String?
    public var latestDigestPartial: Bool
    public var costTodayUSD: Double
    public var dailyBudgetUSD: Double
    /// Next `StartCalendarInterval` of the installed run plist; nil if it is not installed.
    public var nextFire: Date?
    /// The run plist is present in `~/Library/LaunchAgents` (the show plist needs the app bundle).
    public var agentsInstalled: Bool
    public var showAgentInstalled: Bool
    /// `launchctl print gui/<uid>/com.brainmaxxing.run` succeeds.
    public var agentsLoaded: Bool
    public var windowStartHour: Int
    public var windowEndHour: Int
    public var showAtHour: Int
}

public enum SchedulerStatusBuilder {
    /// `home` is the user's home directory (where `Library/LaunchAgents` lives), not the app data directory.
    public static func build(store: Store, config: Config, probe: LaunchctlProbe, home: URL, now: Date,
                             calendar: Calendar = .current) async throws -> SchedulerStatus {
        let fm = FileManager.default
        let runPlist = LaunchAgent.run.plistURL(home: home)
        let installed = fm.fileExists(atPath: runPlist.path)
        let latest = try await store.latestDigest()
        return SchedulerStatus(
            lastRun: try await store.lastRun(),
            lastCompleteRunStart: try await store.lastSuccessfulRun(reaching: Pipeline.completionStage)?.startedAt,
            latestDigestDate: latest?.date,
            latestDigestPartial: latest?.partial ?? false,
            costTodayUSD: try await store.costSince(calendar.startOfDay(for: now)),
            dailyBudgetUSD: config.dailyBudgetUsd,
            nextFire: installed ? LaunchAgentPlist.installedHours(at: runPlist)
                .flatMap { LaunchAgentPlist.nextFire(hours: $0, after: now, calendar: calendar) } : nil,
            agentsInstalled: installed,
            showAgentInstalled: fm.fileExists(atPath: LaunchAgent.show.plistURL(home: home).path),
            agentsLoaded: await probe.isLoaded(label: LaunchAgent.run.label),
            windowStartHour: config.schedule.windowStart,
            windowEndHour: config.schedule.windowEnd,
            showAtHour: config.schedule.showAt)
    }
}
