import Foundation

public enum SchedulingError: LocalizedError, Equatable {
    case invalidWindow(start: Int, end: Int)
    case templatesNotFound
    case appBundleNotFound(String)
    case launchctlFailed(command: String, status: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidWindow(start, end):
            "schedule.window_start (\(start)) must be below schedule.window_end (\(end)), both within 0...24"
        case .templatesNotFound:
            "launchd templates not found (looked in the app bundle's Resources/LaunchAgents and in LaunchAgents/ above the binary)"
        case let .appBundleNotFound(path):
            "no app bundle at \(path)"
        case let .launchctlFailed(command, status, output):
            "`\(command)` exited with \(status): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// The two launchd agents.
public enum LaunchAgent: String, CaseIterable, Sendable {
    case run = "com.brainmaxxing.run"
    case show = "com.brainmaxxing.show"

    public var label: String { rawValue }
    public var templateName: String { "\(rawValue).plist.template" }

    public func plistURL(home: URL) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(rawValue).plist")
    }

    public static func logDirectory(home: URL) -> URL {
        home.appendingPathComponent("Library/Logs/brainmaxxing", isDirectory: true)
    }
}

/// Template rendering for `LaunchAgents/*.plist.template`.
public enum LaunchAgentPlist {
    /// Hours the run agent fires: `[window_start, window_end)`, the same interval the policy accepts.
    public static func windowHours(_ s: Config.Schedule) throws -> [Int] {
        guard s.windowStart >= 0, s.windowEnd <= 24, s.windowStart < s.windowEnd else {
            throw SchedulingError.invalidWindow(start: s.windowStart, end: s.windowEnd)
        }
        return Array(s.windowStart..<s.windowEnd)
    }

    public static func render(template: String, cliPath: String, appPath: String, hours: [Int], logDir: String) -> String {
        let intervals = hours.map { hour in
            """
                    <dict>
                        <key>Hour</key>
                        <integer>\(hour)</integer>
                        <key>Minute</key>
                        <integer>0</integer>
                    </dict>
            """
        }.joined(separator: "\n")
        return template
            .replacingOccurrences(of: "{{CLI_PATH}}", with: xmlEscaped(cliPath))
            .replacingOccurrences(of: "{{APP_PATH}}", with: xmlEscaped(appPath))
            .replacingOccurrences(of: "{{LOG_DIR}}", with: xmlEscaped(logDir))
            .replacingOccurrences(of: "{{CALENDAR_INTERVALS}}", with: intervals)
    }

    /// `StartCalendarInterval` hours of an installed plist (nil if missing or unreadable).
    public static func installedHours(at url: URL) -> [Int]? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let intervals = plist["StartCalendarInterval"] as? [[String: Any]] else { return nil }
        return intervals.compactMap { $0["Hour"] as? Int }
    }

    /// Next time launchd fires one of `hours` (minute 0) after `date`.
    public static func nextFire(hours: [Int], after date: Date, calendar: Calendar = .current) -> Date? {
        hours.compactMap {
            calendar.nextDate(after: date, matching: DateComponents(hour: $0, minute: 0, second: 0), matchingPolicy: .nextTime)
        }.min()
    }

    static func xmlEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// `launchctl print gui/<uid>/<label>` succeeds. Real: `SystemLaunchctl`; tests: a fake.
public protocol LaunchctlProbe: Sendable {
    func isLoaded(label: String) async -> Bool
}

/// Runs `launchctl <arguments>`; throws on a non-zero exit.
public protocol LaunchctlRunner: LaunchctlProbe {
    func run(_ arguments: [String]) async throws
}

public struct SystemLaunchctl: LaunchctlRunner {
    public let uid: uid_t

    public init(uid: uid_t = getuid()) { self.uid = uid }

    public func isLoaded(label: String) async -> Bool {
        (try? Self.launchctl(["print", "gui/\(uid)/\(label)"]).status) == 0
    }

    public func run(_ arguments: [String]) async throws {
        let result = try Self.launchctl(arguments)
        guard result.status == 0 else {
            throw SchedulingError.launchctlFailed(command: InstallStep.launchctl(arguments).description, status: result.status, output: result.output)
        }
    }

    private static func launchctl(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

public enum InstallStep: Sendable, Equatable, CustomStringConvertible {
    case createDirectory(URL)
    case writeFile(URL, contents: String)
    case removeFile(URL)
    case launchctl([String])

    public var description: String {
        switch self {
        case let .createDirectory(url): "mkdir -p \(Self.quoted(url.path))"
        case let .writeFile(url, _): "write \(Self.quoted(url.path))"
        case let .removeFile(url): "rm \(Self.quoted(url.path))"
        case let .launchctl(args): (["launchctl"] + args).map(Self.quoted).joined(separator: " ")
        }
    }

    private static func quoted(_ s: String) -> String {
        s.contains(where: { $0 == " " || $0 == "'" }) ? "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" : s
    }
}

public struct InstallPlan: Sendable, Equatable {
    public var steps: [InstallStep]
    /// Human notes, e.g. "show agent skipped: no app bundle yet".
    public var notes: [String]
    /// Hours the run agent will fire at (empty for uninstall).
    public var runHours: [Int]
}

/// `install-agent` / `uninstall-agent`. Planning is separate from applying so that `--dry-run`
/// prints exactly what `apply` would do. Both plans are idempotent: an agent is booted out only if loaded,
/// a file is removed only if present.
public enum AgentInstaller {
    public static func planInstall(cliPath: URL, appPath: URL?, templates: URL, config: Config, home: URL, uid: uid_t,
                                   probe: LaunchctlProbe) async throws -> InstallPlan {
        let hours = try LaunchAgentPlist.windowHours(config.schedule)
        let logDir = LaunchAgent.logDirectory(home: home)
        var steps: [InstallStep] = [
            .createDirectory(home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)),
            .createDirectory(logDir),
        ]
        var notes = pathWarnings(cliPath: cliPath, home: home)
        for agent in LaunchAgent.allCases {
            if agent == .show && appPath == nil {
                notes.append("show agent skipped: no app bundle yet")
                continue
            }
            let templateURL = templates.appendingPathComponent(agent.templateName)
            let template: String
            do { template = try String(contentsOf: templateURL, encoding: .utf8) } catch { throw SchedulingError.templatesNotFound }
            let rendered = LaunchAgentPlist.render(template: template, cliPath: cliPath.path, appPath: appPath?.path ?? "",
                                                   hours: agent == .run ? hours : [config.schedule.showAt], logDir: logDir.path)
            let plist = agent.plistURL(home: home)
            if await probe.isLoaded(label: agent.label) { steps.append(.launchctl(["bootout", "gui/\(uid)/\(agent.label)"])) }
            steps.append(.writeFile(plist, contents: rendered))
            steps.append(.launchctl(["bootstrap", "gui/\(uid)", plist.path]))
        }
        return InstallPlan(steps: steps, notes: notes, runHours: hours)
    }

    /// Warnings (install proceeds) for a binary launchd will fail to run later: under `~/Desktop`, `~/Documents` or
    /// `~/Downloads` (TCC denies launchd jobs there) or inside a `.build/` directory (gone after `swift package clean`).
    public static func pathWarnings(cliPath: URL, home: URL) -> [String] {
        let resolved = cliPath.resolvingSymlinksInPath()
        let path = resolved.path
        let homes = Set([home.standardizedFileURL.path, home.resolvingSymlinksInPath().path])
        var warnings: [String] = []
        if let dir = ["Desktop", "Documents", "Downloads"].first(where: { d in homes.contains { path.hasPrefix("\($0)/\(d)/") } }) {
            warnings.append("warning: \(path) is under ~/\(dir), which macOS privacy protection (TCC) blocks for launchd jobs; "
                            + "the scheduled run will fail. Install brainmaxxing.app in /Applications and run install-agent from it.")
        }
        if resolved.pathComponents.contains(".build") {
            warnings.append("warning: \(path) is inside a .build/ directory; `swift package clean` or a rebuild elsewhere breaks "
                            + "the agent. Install brainmaxxing.app in /Applications and run install-agent from it.")
        }
        return warnings
    }

    public static func planUninstall(home: URL, uid: uid_t, probe: LaunchctlProbe) async -> InstallPlan {
        var steps: [InstallStep] = []
        for agent in LaunchAgent.allCases {
            if await probe.isLoaded(label: agent.label) { steps.append(.launchctl(["bootout", "gui/\(uid)/\(agent.label)"])) }
            let plist = agent.plistURL(home: home)
            if FileManager.default.fileExists(atPath: plist.path) { steps.append(.removeFile(plist)) }
        }
        return InstallPlan(steps: steps, notes: steps.isEmpty ? ["nothing installed"] : [], runHours: [])
    }

    public static func apply(_ plan: InstallPlan, runner: LaunchctlRunner) async throws {
        let fm = FileManager.default
        for step in plan.steps {
            switch step {
            case let .createDirectory(url):
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            case let .writeFile(url, contents):
                try Data(contents.utf8).write(to: url, options: .atomic)
            case let .removeFile(url):
                try fm.removeItem(at: url)
            case let .launchctl(args):
                try await runner.run(args)
                // bootout returns before the service is gone; a bootstrap right after can fail with EIO.
                if args.first == "bootout", let label = args.last?.split(separator: "/").last.map(String.init) {
                    for _ in 0..<50 where await runner.isLoaded(label: label) {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
        }
    }

    /// Absolute path of the running binary, symlinks resolved.
    public static func currentExecutable() -> URL? {
        Bundle.main.executableURL?.resolvingSymlinksInPath()
    }

    /// `brainmaxxing.app` containing `executable` (release: `....app/Contents/MacOS/digest-cli`), else one next to it.
    public static func locateApp(executable: URL) -> URL? {
        var dir = executable.deletingLastPathComponent()
        while dir.path != "/" {
            if dir.pathExtension == "app" { return dir }
            dir = dir.deletingLastPathComponent()
        }
        let sibling = executable.deletingLastPathComponent().appendingPathComponent("brainmaxxing.app", isDirectory: true)
        return FileManager.default.fileExists(atPath: sibling.path) ? sibling : nil
    }

    /// Template directory: `Contents/Resources/LaunchAgents` of the enclosing app, else the first `LaunchAgents/`
    /// holding the templates in a parent directory of the binary (dev: the repo root above `.build/`).
    public static func locateTemplates(executable: URL) -> URL? {
        let fm = FileManager.default
        func hasTemplates(_ dir: URL) -> Bool {
            LaunchAgent.allCases.allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0.templateName).path) }
        }
        if let app = locateApp(executable: executable), executable.path.hasPrefix(app.path + "/") {
            let bundled = app.appendingPathComponent("Contents/Resources/LaunchAgents", isDirectory: true)
            if hasTemplates(bundled) { return bundled }
        }
        var dir = executable.deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("LaunchAgents", isDirectory: true)
            if hasTemplates(candidate) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
