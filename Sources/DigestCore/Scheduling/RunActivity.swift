import Foundation

/// Keeps a started pipeline run from being suspended by idle system sleep (qa P2). Display sleep and lid close
/// still apply; only the idle timer is held off until `body` returns or throws.
public enum RunActivity {
    public static func preventingIdleSleep<T>(_ body: () async throws -> T) async rethrows -> T {
        let token = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                                                          reason: "brainmaxxing digest run")
        defer { ProcessInfo.processInfo.endActivity(token) }
        return try await body()
    }
}
