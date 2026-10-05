import Foundation
import Testing
@testable import DigestCore

struct FakeIdle: IdleSource {
    var idle: TimeInterval
    var asleep = false
    func idleSeconds() async -> TimeInterval { idle }
    func displayAsleep() async -> Bool { asleep }
}

/// Fake launchctl: `bootstrap` loads the plist's label, `bootout` unloads it; every call is recorded.
actor FakeLaunchctl: LaunchctlRunner {
    private(set) var loaded: Set<String>
    private(set) var calls: [[String]] = []

    init(loaded: Set<String> = []) { self.loaded = loaded }

    func isLoaded(label: String) async -> Bool { loaded.contains(label) }

    func run(_ arguments: [String]) async throws {
        calls.append(arguments)
        switch arguments.first {
        case "bootstrap": loaded.insert(URL(fileURLWithPath: arguments[2]).deletingPathExtension().lastPathComponent)
        case "bootout": loaded.remove(String(arguments[1].split(separator: "/").last ?? ""))
        default: break
        }
    }
}

private let berlin: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
    return c
}()

private let repoRoot = TestSupport.fixtures.deletingLastPathComponent().deletingLastPathComponent()

private func lint(_ url: URL) throws -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
    p.arguments = ["-lint", "-s", url.path]
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus == 0
}

@Suite struct DefaultRunPolicyTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var now: String                 // ISO 8601 with offset, interpreted in Europe/Berlin
        var lastSuccess: String?
        var idle: TimeInterval
        var asleep = false
        var run: Bool
        var reason: String
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "idle inside window", now: "2026-10-22T04:10:00+02:00", idle: 20 * 60, run: true, reason: "user idle 20 min"),
        Case(name: "active inside window", now: "2026-10-22T04:10:00+02:00", idle: 3 * 60 + 30, run: false, reason: "user active 3 min ago"),
        Case(name: "active but display asleep", now: "2026-10-22T04:10:00+02:00", idle: 60, asleep: true, run: true, reason: "display asleep"),
        Case(name: "idle exactly the threshold", now: "2026-10-22T05:00:00+02:00", idle: 15 * 60, run: true, reason: "user idle 15 min"),
        Case(name: "idle one second short", now: "2026-10-22T05:00:00+02:00", idle: 15 * 60 - 1, run: false, reason: "user active 14 min ago"),
        Case(name: "window start is inclusive", now: "2026-10-22T03:00:00+02:00", idle: 3600, run: true, reason: "user idle 60 min"),
        Case(name: "before window", now: "2026-10-22T02:59:00+02:00", idle: 3600, asleep: true, run: false, reason: "outside the 03:00-09:00 window"),
        Case(name: "window end is exclusive", now: "2026-10-22T09:00:00+02:00", idle: 3600, run: false, reason: "outside the 03:00-09:00 window"),
        Case(name: "evening", now: "2026-10-22T22:00:00+02:00", idle: 3600, run: false, reason: "outside the 03:00-09:00 window"),
        Case(name: "done today", now: "2026-10-22T05:00:00+02:00", lastSuccess: "2026-10-22T03:05:00+02:00", idle: 3600, asleep: true,
             run: false, reason: "already ran today at 03:05"),
        Case(name: "done today after midnight (manual run)", now: "2026-10-22T04:00:00+02:00", lastSuccess: "2026-10-22T00:10:00+02:00",
             idle: 3600, run: false, reason: "already ran today at 00:10"),
        Case(name: "last success yesterday 23:50", now: "2026-10-22T03:10:00+02:00", lastSuccess: "2026-10-21T23:50:00+02:00",
             idle: 3600, run: true, reason: "user idle 60 min"),
        // Spring forward (2026-03-29 02:00 CET -> 03:00 CEST): the 23-hour day still has its window.
        Case(name: "DST spring: first hour after the jump", now: "2026-03-29T03:30:00+02:00", lastSuccess: "2026-03-28T23:50:00+01:00",
             idle: 3600, run: true, reason: "user idle 60 min"),
        // Fall back (2026-10-25 03:00 CEST -> 02:00 CET): 02:xx happens twice, both outside the window.
        Case(name: "DST fall: repeated 02:30 is outside", now: "2026-10-25T02:30:00+01:00", idle: 3600, run: false,
             reason: "outside the 03:00-09:00 window"),
        Case(name: "DST fall: run in the first 02:30 does not count", now: "2026-10-25T03:10:00+01:00", lastSuccess: "2026-10-24T23:50:00+02:00",
             idle: 3600, run: true, reason: "user idle 60 min"),
        Case(name: "DST fall: done in the 25-hour day", now: "2026-10-25T08:50:00+01:00", lastSuccess: "2026-10-25T03:10:00+01:00",
             idle: 3600, run: false, reason: "already ran today at 03:10"),
    ]

    @Test(arguments: cases) func decides(_ c: Case) async throws {
        let policy = DefaultRunPolicy(config: Config(), idle: FakeIdle(idle: c.idle, asleep: c.asleep), calendar: berlin)
        let decision = await policy.shouldRun(now: try TestSupport.date(c.now), lastSuccess: try c.lastSuccess.map(TestSupport.date))
        #expect(decision == RunDecision(run: c.run, reason: c.reason))
    }

    @Test func usesConfiguredWindowAndIdle() async throws {
        let config = Config(schedule: Config.Schedule(windowStart: 1, windowEnd: 2, idleMinutes: 5))
        let policy = DefaultRunPolicy(config: config, idle: FakeIdle(idle: 5 * 60), calendar: berlin)
        #expect(await policy.shouldRun(now: try TestSupport.date("2026-10-22T01:30:00+02:00"), lastSuccess: nil).run)
        #expect(await policy.shouldRun(now: try TestSupport.date("2026-10-22T03:30:00+02:00"), lastSuccess: nil).reason
                == "outside the 01:00-02:00 window")
    }
}

@Suite struct LaunchAgentTests {
    func render(_ agent: LaunchAgent) throws -> String {
        let template = try String(contentsOf: repoRoot.appendingPathComponent("LaunchAgents/\(agent.templateName)"), encoding: .utf8)
        return LaunchAgentPlist.render(template: template, cliPath: "/Applications/brainmaxxing.app/Contents/MacOS/digest-cli",
                                       appPath: "/Applications/brainmaxxing.app",
                                       hours: agent == .run ? try LaunchAgentPlist.windowHours(Config().schedule) : [Config().schedule.showAt],
                                       logDir: "/Users/tester/Library/Logs/brainmaxxing")
    }

    @Test(arguments: LaunchAgent.allCases) func renderMatchesGoldenAndLints(_ agent: LaunchAgent) throws {
        let rendered = try render(agent)
        let golden = try String(decoding: TestSupport.fixture("launchd/\(agent.label).plist"), as: UTF8.self)
        #expect(rendered == golden)
        let out = try TestSupport.tempDirectory().appendingPathComponent("\(agent.label).plist")
        try Data(rendered.utf8).write(to: out)
        #expect(try lint(out))
        #expect(LaunchAgentPlist.installedHours(at: out) == (agent == .run ? [3, 4, 5, 6, 7, 8] : [10]))
    }

    @Test func escapesPaths() {
        #expect(LaunchAgentPlist.render(template: "<string>{{CLI_PATH}}</string>", cliPath: "/a&b/<c>", appPath: "", hours: [], logDir: "")
                == "<string>/a&amp;b/&lt;c&gt;</string>")
    }

    @Test(arguments: [(9, 3), (5, 5), (-1, 4), (3, 25)]) func rejectsInvalidWindow(_ window: (Int, Int)) {
        #expect(throws: SchedulingError.invalidWindow(start: window.0, end: window.1)) {
            try LaunchAgentPlist.windowHours(Config.Schedule(windowStart: window.0, windowEnd: window.1))
        }
    }

    @Test func nextFireCrossesMidnight() throws {
        let hours = [3, 4, 5, 6, 7, 8]
        #expect(LaunchAgentPlist.nextFire(hours: hours, after: try TestSupport.date("2026-10-22T00:30:00+02:00"), calendar: berlin)
                == (try TestSupport.date("2026-10-22T03:00:00+02:00")))
        #expect(LaunchAgentPlist.nextFire(hours: hours, after: try TestSupport.date("2026-10-22T08:30:00+02:00"), calendar: berlin)
                == (try TestSupport.date("2026-10-23T03:00:00+02:00")))
        #expect(LaunchAgentPlist.nextFire(hours: [], after: Date()) == nil)
    }

    @Test func locatesAppAndTemplates() throws {
        let inBundle = URL(fileURLWithPath: "/Applications/brainmaxxing.app/Contents/MacOS/digest-cli")
        #expect(AgentInstaller.locateApp(executable: inBundle)?.path == "/Applications/brainmaxxing.app")

        let dir = try TestSupport.tempDirectory()
        let dev = dir.appendingPathComponent("digest-cli")
        #expect(AgentInstaller.locateApp(executable: dev) == nil)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("brainmaxxing.app"), withIntermediateDirectories: true)
        #expect(AgentInstaller.locateApp(executable: dev)?.lastPathComponent == "brainmaxxing.app")

        // Dev layout: templates are found in the repo's LaunchAgents/ above .build/.
        let devBinary = repoRoot.appendingPathComponent(".build/out/Products/Debug/digest-cli")
        #expect(AgentInstaller.locateTemplates(executable: devBinary)?.standardizedFileURL
                == repoRoot.appendingPathComponent("LaunchAgents", isDirectory: true).standardizedFileURL)
    }
}

@Suite struct AgentInstallerTests {
    let cli = URL(fileURLWithPath: "/Users/tester/dev/.build/debug/digest-cli")
    let templates = repoRoot.appendingPathComponent("LaunchAgents", isDirectory: true)

    @Test func dryRunPlanWithoutAppSkipsShowAndWritesNothing() async throws {
        let home = try TestSupport.tempDirectory()
        let probe = FakeLaunchctl()
        let plan = try await AgentInstaller.planInstall(cliPath: cli, appPath: nil, templates: templates, config: Config(),
                                                        home: home, uid: 501, probe: probe)
        let runPlist = home.appendingPathComponent("Library/LaunchAgents/com.brainmaxxing.run.plist")
        #expect(plan.steps.map(\.description) == [
            "mkdir -p \(home.path)/Library/LaunchAgents",
            "mkdir -p \(home.path)/Library/Logs/brainmaxxing",
            "write \(runPlist.path)",
            "launchctl bootstrap gui/501 \(runPlist.path)",
        ])
        #expect(plan.notes == AgentInstaller.pathWarnings(cliPath: cli, home: home) + ["show agent skipped: no app bundle yet"])
        #expect(plan.notes.first?.hasPrefix("warning: \(cli.path) is inside a .build/ directory") == true)
        #expect(plan.runHours == [3, 4, 5, 6, 7, 8])
        // Planning (what --dry-run prints) touches neither the file system nor launchctl.
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
        #expect(await probe.calls.isEmpty)
    }

    @Test(arguments: [
        ("Desktop/brainmaxxing/digest-cli", ["~/Desktop"]),
        ("Documents/x/digest-cli", ["~/Documents"]),
        ("Downloads/brainmaxxing.app/Contents/MacOS/digest-cli", ["~/Downloads"]),
        ("Desktop/repo/.build/debug/digest-cli", ["~/Desktop", ".build/"]),
        ("dev/repo/.build/arm64-apple-macosx/debug/digest-cli", [".build/"]),
        ("Applications/brainmaxxing.app/Contents/MacOS/digest-cli", []),
        ("DesktopBackup/digest-cli", []),
    ])
    func installWarnsAboutFragileBinaryPaths(relative: String, expected: [String]) async throws {
        let home = try TestSupport.tempDirectory()
        let exe = home.appendingPathComponent(relative)
        let warnings = AgentInstaller.pathWarnings(cliPath: exe, home: home)
        #expect(warnings.count == expected.count)
        for (warning, marker) in zip(warnings, expected) {
            #expect(warning.hasPrefix("warning: ") && warning.contains(marker) && warning.contains("/Applications"))
        }
        // Warning only: the plan still writes and bootstraps the run agent.
        let plan = try await AgentInstaller.planInstall(cliPath: exe, appPath: nil, templates: templates, config: Config(),
                                                        home: home, uid: 501, probe: FakeLaunchctl())
        #expect(Array(plan.notes.prefix(warnings.count)) == warnings)
        #expect(plan.steps.contains(.launchctl(["bootstrap", "gui/501", LaunchAgent.run.plistURL(home: home).path])))
    }

    @Test func installReplacesLoadedAgentsThenUninstallIsIdempotent() async throws {
        let home = try TestSupport.tempDirectory()
        let app = URL(fileURLWithPath: "/Applications/brainmaxxing.app")
        let launchctl = FakeLaunchctl(loaded: ["com.brainmaxxing.run"])
        let plan = try await AgentInstaller.planInstall(cliPath: cli, appPath: app, templates: templates, config: Config(),
                                                        home: home, uid: 501, probe: launchctl)
        let commands = plan.steps.compactMap { step -> String? in if case .launchctl = step { step.description } else { nil } }
        let agents = "\(home.path)/Library/LaunchAgents"
        #expect(commands == [
            "launchctl bootout gui/501/com.brainmaxxing.run",
            "launchctl bootstrap gui/501 \(agents)/com.brainmaxxing.run.plist",
            "launchctl bootstrap gui/501 \(agents)/com.brainmaxxing.show.plist",
        ])
        try await AgentInstaller.apply(plan, runner: launchctl)
        #expect(await launchctl.loaded == ["com.brainmaxxing.run", "com.brainmaxxing.show"])
        for agent in LaunchAgent.allCases { #expect(try lint(agent.plistURL(home: home))) }
        #expect(FileManager.default.fileExists(atPath: LaunchAgent.logDirectory(home: home).path))
        let show = try String(contentsOf: LaunchAgent.show.plistURL(home: home), encoding: .utf8)
        #expect(show.contains("<string>/Applications/brainmaxxing.app</string>"))

        let uninstall = await AgentInstaller.planUninstall(home: home, uid: 501, probe: launchctl)
        #expect(uninstall.steps.map(\.description) == [
            "launchctl bootout gui/501/com.brainmaxxing.run", "rm \(agents)/com.brainmaxxing.run.plist",
            "launchctl bootout gui/501/com.brainmaxxing.show", "rm \(agents)/com.brainmaxxing.show.plist",
        ])
        try await AgentInstaller.apply(uninstall, runner: launchctl)
        #expect(await launchctl.loaded.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: LaunchAgent.run.plistURL(home: home).path))

        let again = await AgentInstaller.planUninstall(home: home, uid: 501, probe: launchctl)
        #expect(again.steps.isEmpty)
        #expect(again.notes == ["nothing installed"])
    }

    @Test func quotesPathsWithSpaces() {
        #expect(InstallStep.launchctl(["bootstrap", "gui/501", "/Users/a b/x.plist"]).description
                == "launchctl bootstrap gui/501 '/Users/a b/x.plist'")
    }
}

@Suite struct SchedulerStatusTests {
    func sampleDigest(date: String, runID: String, partial: Bool) -> Digest {
        Digest(title: "T", summary: "s", clusters: [], papers: [], hfSection: [], trendNotes: "", date: date, runID: runID,
               generatedAt: Date(timeIntervalSince1970: 1_800_000_000), partial: partial, empty: false, counts: RunCounts(),
               promptVersion: 1, model: "claude-opus-5-5", costUSD: 1.5)
    }

    @Test func emptyStoreNothingInstalled() async throws {
        let status = try await SchedulerStatusBuilder.build(store: try tempStore(), config: Config(), probe: FakeLaunchctl(),
                                                            home: try TestSupport.tempDirectory(), now: Date(), calendar: berlin)
        #expect(status == SchedulerStatus(lastRun: nil, lastCompleteRunStart: nil, latestDigestDate: nil, latestDigestPartial: false,
                                          costTodayUSD: 0, dailyBudgetUSD: 4, nextFire: nil, agentsInstalled: false,
                                          showAgentInstalled: false, agentsLoaded: false, windowStartHour: 3, windowEndHour: 9,
                                          showAtHour: 10))
    }

    @Test func reportsRunsCostDigestAndAgents() async throws {
        let store = try tempStore()
        let home = try TestSupport.tempDirectory()
        let started = try TestSupport.date("2026-10-22T03:05:00+02:00")
        let now = try TestSupport.date("2026-10-22T08:30:00+02:00")
        try await store.startRun(id: "r1", startedAt: started, force: false, since: nil, stages: .all)
        try await store.markStageReached("r1", stage: .digest)
        try await store.finishRun("r1", status: .succeeded, partial: true, counts: RunCounts(), promptVersions: [:], errorSummary: nil,
                                  finishedAt: started.addingTimeInterval(600))
        try await store.recordLLMCall(LLMCallRecord(runID: "r1", stage: .digest, model: "claude-opus-5-5", promptName: "digest",
                                                    promptVersion: 1, usage: LLMUsage(inputTokens: 1, outputTokens: 1),
                                                    usdEstimate: 1.25, createdAt: started))
        try await store.saveDigest(sampleDigest(date: "2026-10-22", runID: "r1", partial: true))

        let launchctl = FakeLaunchctl()
        let plan = try await AgentInstaller.planInstall(cliPath: URL(fileURLWithPath: "/x/digest-cli"), appPath: nil,
                                                        templates: repoRoot.appendingPathComponent("LaunchAgents"), config: Config(),
                                                        home: home, uid: 501, probe: launchctl)
        try await AgentInstaller.apply(plan, runner: launchctl)

        let status = try await SchedulerStatusBuilder.build(store: store, config: Config(), probe: launchctl, home: home, now: now,
                                                            calendar: berlin)
        #expect(status.lastRun?.id == "r1")
        #expect(status.lastCompleteRunStart == started)
        #expect(status.latestDigestDate == "2026-10-22")
        #expect(status.latestDigestPartial)
        #expect(abs(status.costTodayUSD - 1.25) < 1e-9)
        #expect(status.agentsInstalled && status.agentsLoaded && !status.showAgentInstalled)
        #expect(status.nextFire == (try TestSupport.date("2026-10-23T03:00:00+02:00")))
    }
}
