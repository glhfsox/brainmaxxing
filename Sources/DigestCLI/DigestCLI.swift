import ArgumentParser
import DigestCore
import Foundation

@main
struct DigestCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "digest-cli",
        abstract: "brainmaxxing pipeline runner.",
        subcommands: [Run.self, Status.self, Show.self, Cost.self, PromptsCommand.self, RecordFixture.self, RecordGolden.self, InstallAgent.self, UninstallAgent.self])
}

/// Human output on stdout, diagnostics on stderr.
enum Console {
    static func out(_ s: String) { print(s) }
    static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    static func usd(_ v: Double) -> String { String(format: "$%.4f", v) }

    /// Runs `body`; a thrown error becomes one `error:` line on stderr and exit code 1.
    static func guarded(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let exit as ExitCode {
            throw exit
        } catch {
            err("error: \(error.localizedDescription)")
            throw ExitCode(1)
        }
    }
}

struct Environment {
    let paths: AppPaths
    let config: Config
    let store: Store

    static func load() throws -> Environment {
        let paths = AppPaths.resolve()
        return Environment(paths: paths, config: try Config.load(home: paths.home), store: try Store(url: paths.database))
    }
}

enum StageOption: String, ExpressibleByArgument, CaseIterable {
    case fetch, triage, digest

    /// `digest` is not a stage range: it re-runs the digest of the latest run that reached select.
    var stages: Set<Stage> {
        switch self {
        case .fetch: Stage.dedup.throughHere
        case .triage: Stage.select.throughHere
        case .digest: [.fulltext, .digest]
        }
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the pipeline.")

    @Flag(help: "Run even if a run already completed today.") var force = false
    @Flag(help: "Scheduled invocation: run only if due (window, idle, not done today); otherwise print why and exit 0.") var ifDue = false
    @Option(help: "fetch | triage: run up to that stage. digest: re-run full text + digest for the latest run that reached select.")
    var stage: StageOption?
    @Option(help: "Comma-separated arXiv categories, overriding config.") var categories: String?
    @Option(help: "Override daily_budget_usd for this run.") var budgetUsd: Double?

    func run() async throws {
        try await Console.guarded {
            let env = try Environment.load()
            var config = env.config
            if let budgetUsd { config.dailyBudgetUsd = budgetUsd }

            if ifDue {
                let now = Date()
                let stamp = now.formatted(.iso8601)
                if try await env.store.digest(date: LocalDate.string(now)) != nil {
                    Console.out("\(stamp) if-due: skip, a digest for today exists")
                    return
                }
                // A retry would buy the same failure again; transient failures fall through to the policy.
                if let failed = try await env.store.deterministicDigestFailure(onDayOf: now) {
                    Console.out("\(stamp) if-due: skip, run \(failed.id) failed the digest today with an error a retry would repeat (\(failed.errors[.digest] ?? "unknown")); use run --force")
                    return
                }
                let last = try await env.store.lastSuccessfulRun(reaching: Pipeline.completionStage)
                let decision = await DefaultRunPolicy(config: config, idle: IOKitIdleSource()).shouldRun(now: now, lastSuccess: last?.startedAt)
                Console.out("\(stamp) if-due: \(decision.run ? "run" : "skip"), \(decision.reason)")
                guard decision.run else { return }
            }

            // A started run holds off idle system sleep until it finishes or fails (qa P2).
            try await RunActivity.preventingIdleSleep {
                // Unattended (launchd) runs never wait on a Keychain dialog.
                let apiKey = try KeychainStore.resolveAnthropicKey(mode: ifDue ? .nonInteractive : .interactive)
                let meter = CostMeter(store: env.store, dailyBudgetUSD: config.dailyBudgetUsd)
                let llm = AnthropicClient(apiKey: apiKey, costMeter: meter)
                // One limiter for every arxiv.org / export.arxiv.org request (3 s).
                let arxivLimiter = RateLimiter(minInterval: 3)
                let archive = RawArchive(root: env.paths.raw)
                let arxiv = ArxivClient(rateLimiter: arxivLimiter, includeReversions: config.includeReversions, archive: archive)
                // Secondary sources: their own pacing, never the arXiv limiter; failures never make the run partial.
                var sources: [PaperSource] = [arxiv]
                if config.sources.openalex {
                    sources.append(OpenAlexClient(subfields: config.openalexSubfields, maxPerRun: config.openalexMaxPerRun, archive: archive))
                }
                let pipeline = Pipeline(store: env.store, sources: sources, llm: llm,
                                        prompts: try PromptLoader.bundled(pins: config.promptPins), config: config,
                                        fullText: ArxivFullTextFetcher(rateLimiter: arxivLimiter),
                                        hfPapers: config.sources.hfPapers ? HFPapersClient(archive: archive) : nil)
                if stage == .digest {
                    try await printReport(try await StopSignals.cancelling { try await pipeline.rerunDigest() }, store: env.store, home: env.paths.home)
                    return
                }
                let cats = categories?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

                let report: RunReport
                do {
                    let (force, stages) = (force, stage?.stages ?? .all)
                    report = try await StopSignals.cancelling { try await pipeline.run(force: force, stages: stages, categories: cats) }
                } catch let error as PipelineError {
                    if case .alreadyCompletedToday = error {
                        Console.out(error.localizedDescription)
                        return
                    }
                    throw error
                }
                try await printReport(report, store: env.store, home: env.paths.home)
            }
        }
    }

    private func printReport(_ r: RunReport, store: Store, home: URL) async throws {
        let c = r.counts
        Console.out("run \(r.runID)  fetched \(c.fetched) / deduped \(c.deduped) / new \(c.new) / triaged \(c.triaged) / selected \(c.selected) / fulltext \(c.fulltext) / written \(c.written)  cost \(Console.usd(r.totalCost))\(r.partial ? "  (partial)" : "")")
        let selected = try await store.rankedPapers(runID: r.runID, selectedOnly: true)
        for p in selected {
            // *: scored by an earlier run and carried over.
            let mark = p.scoredInRunID == r.runID ? " " : "*"
            Console.out("\(String(format: "%2d", p.score)) \(mark) \(p.paper.id)  \(p.paper.title) - \(p.oneLine)")
        }
        let selectedFromThisRun = selected.filter { $0.scoredInRunID == r.runID }.count
        if c.triaged > 0 || c.selected > 0 { Console.out("also seen: \(max(0, c.triaged - selectedFromThisRun))") }
        if let run = try await store.run(id: r.runID), let digest = try await store.digest(date: LocalDate.string(run.startedAt)) {
            if digest.runID != r.runID {
                // Reached the digest stage but wrote nothing: the pool had no unshown paper >= min_score.
                if run.lastStage == .digest, r.errors[.digest] == nil {
                    Console.out("nothing new since edition \(digest.edition) of \(digest.date)")
                }
            } else if digest.empty {
                Console.out("\(digest.title). \(digest.summary)")
            } else {
                let edition = digest.edition > 1 ? " edition \(digest.edition)" : ""
                Console.out("digest \(digest.date)\(edition): \(digest.title) - \(digest.papers.count) papers, \(digest.clusters.count) clusters\(digest.partial ? " (partial)" : "")")
                Console.out(digest.summary)
                Console.out("read it: digest-cli show")
            }
        }
        if c.openalex + c.openalexMerged + c.openalexDropped > 0 || c.hf > 0 {
            Console.out("openalex \(c.openalex) kept / \(c.openalexMerged) arXiv copies / \(c.openalexDropped) dropped\(c.openalexCapped > 0 ? " (capped)" : "")  hf \(c.hf)")
        }
        if c.unscored > 0 { Console.err("warning: \(c.unscored) papers were left unscored by the model") }
        for (stage, error) in r.errors.sorted(by: { $0.key < $1.key }) {
            Console.err("warning: \(stage.rawValue): \(error.localizedDescription)")
        }
        for warning in r.warnings { Console.err("warning: \(warning)") }
    }
}

/// "Stop run" in the app sends SIGTERM; Ctrl-C sends SIGINT. Either cancels the pipeline instead of killing the process,
/// so the in-flight LLM call is billed (estimated) and the run is stored as partial "stopped by user". The run
/// then throws `PipelineError.stoppedByUser`, which exits 1.
enum StopSignals {
    static func cancelling<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task { try await operation() }
        let sources = [SIGTERM, SIGINT].map { sig in
            signal(sig, SIG_IGN)  // the dispatch source only sees signals whose default action is ignored
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                Console.err("received \(sig == SIGTERM ? "SIGTERM" : "SIGINT"), stopping the run")
                task.cancel()
            }
            source.resume()
            return source
        }
        defer {
            for source in sources { source.cancel() }
            for sig in [SIGTERM, SIGINT] { signal(sig, SIG_DFL) }
        }
        return try await task.value
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Last run, cost today, next window.")

    func run() async throws {
        try await Console.guarded {
            let env = try Environment.load()
            let now = Date()
            let status = try await SchedulerStatusBuilder.build(store: env.store, config: env.config, probe: SystemLaunchctl(),
                                                                home: UserHome.url, now: now)
            if let last = status.lastRun {
                let c = last.counts
                Console.out("last run: \(last.id)  \(last.startedAt.formatted(date: .abbreviated, time: .shortened))  \(last.status.rawValue)\(last.partial && last.status != .partial ? " (partial)" : "")  fetched \(c.fetched) / new \(c.new) / triaged \(c.triaged) / selected \(c.selected)")
                if let errors = last.errorSummary { Console.out("  errors: \(errors)") }
                if let ok = status.lastCompleteRunStart {
                    Console.out("last complete run: \(ok.formatted(date: .abbreviated, time: .shortened))")
                }
            } else {
                Console.out("no runs yet")
            }
            if let digest = try await env.store.digest(date: LocalDate.string(now)) {
                Console.out("digest today: \(digest.title)  (\(digest.empty ? "empty" : "\(digest.papers.count) papers")\(digest.partial ? ", partial" : ""))")
            } else {
                Console.out("digest today: none")
                if let date = status.latestDigestDate { Console.out("latest digest: \(date)\(status.latestDigestPartial ? " (partial)" : "")") }
            }
            Console.out("cost today: \(Console.usd(status.costTodayUSD)) of \(String(format: "$%.2f", status.dailyBudgetUSD))")
            Console.out(String(format: "schedule: window %02d:00-%02d:00 (idle >= %d min), show at %02d:00",
                               status.windowStartHour, status.windowEndHour, env.config.schedule.idleMinutes, status.showAtHour))
            let run = status.agentsInstalled ? (status.agentsLoaded ? "installed, loaded" : "installed, NOT loaded") : "not installed"
            Console.out("agents: run \(run); show \(status.showAgentInstalled ? "installed" : "not installed")")
            if let next = status.nextFire {
                Console.out("next fire: \(next.formatted(date: .abbreviated, time: .shortened))")
            } else {
                Console.out("next fire: none (run `digest-cli install-agent`)")
            }
        }
    }
}

struct Cost: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "LLM cost per day.")

    @Option(help: "Number of days to show, including today.") var days = 7

    func run() async throws {
        try await Console.guarded {
            let env = try Environment.load()
            guard try await env.store.lastRun() != nil else {
                Console.out("no runs yet")
                return
            }
            let start = Calendar.current.date(byAdding: .day, value: -(max(days, 1) - 1), to: Calendar.current.startOfDay(for: Date())) ?? Date()
            let rows = try await env.store.dailyCosts(since: start)
            guard !rows.isEmpty else {
                Console.out("no LLM calls in the last \(days) days")
                return
            }
            for row in rows {
                Console.out("\(LocalDate.string(row.day))  \(Console.usd(row.usd))  chat \(Console.usd(row.chatUSD))  (\(row.calls) calls)")
            }
            Console.out("total       \(Console.usd(rows.reduce(0) { $0 + $1.usd }))  chat \(Console.usd(rows.reduce(0) { $0 + $1.chatUSD }))")
        }
    }
}

struct RecordFixture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Record raw API responses as test fixtures (live network).")

    enum Source: String, ExpressibleByArgument, CaseIterable { case arxiv, openalex, hf }

    @Argument(help: "Source to record: arxiv | openalex | hf.") var source: Source
    @Option(help: "ISO 8601 lower bound: arXiv `updated`, OpenAlex publication date; for hf, the listing date (default: 24 h ago).") var since: String?
    @Option(help: "Output directory (default: Tests/Fixtures/<source>/recorded-<date>).") var out: String?
    @Option(help: "Maximum pages to fetch (arxiv, openalex).") var maxPages = 2

    func run() async throws {
        try await Console.guarded {
            let env = try Environment.load()
            let sinceDate: Date
            if let since {
                guard let parsed = try? Date(since, strategy: .iso8601) else { throw ValidationError("--since must be ISO 8601, e.g. 2026-10-20T00:00:00Z") }
                sinceDate = parsed
            } else {
                sinceDate = Date().addingTimeInterval(-86_400)
            }
            let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.omitted))
            let dir = URL(fileURLWithPath: out ?? "Tests/Fixtures/\(source.rawValue)/recorded-\(stamp)", isDirectory: true)
            switch source {
            case .arxiv:
                let client = ArxivClient(includeReversions: true, pageSize: 100, maxPages: maxPages, archive: RawArchive(root: dir))
                let result = try await client.fetch(since: sinceDate, categories: env.config.categories)
                Console.out("recorded \(result.papers.count) entries into \(dir.path)\(result.truncated ? " (page cap hit)" : "")")
            case .openalex:
                // Anonymous, like the pipeline: no mailto, no api_key.
                let client = OpenAlexClient(subfields: env.config.openalexSubfields, maxPerRun: max(1, maxPages) * 200, archive: RawArchive(root: dir))
                let result = try await client.fetch(since: sinceDate, categories: [])
                Console.out("recorded OpenAlex pages into \(dir.path): \(result.papers.count) kept, \(result.merged) arXiv copies, \(result.dropped) dropped\(result.capped ? " (capped)" : "")")
            case .hf:
                let day = LocalDate.string(sinceDate)
                let papers = try await HFPapersClient(archive: RawArchive(root: dir)).daily(date: day)
                Console.out("recorded \(papers.count) HF Daily Papers for \(day) into \(dir.path)")
            }
        }
    }
}

struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print a stored digest (latest by default) as Markdown or JSON.")

    @Option(help: "Local date YYYY-MM-DD (default: the latest digest).") var date: String?
    @Option(help: "Edition of that date (default: the latest; needs --date).") var edition: Int?
    @Flag(help: "Print the stored digest JSON.") var json = false

    func validate() throws {
        if edition != nil, date == nil { throw ValidationError("--edition needs --date") }
    }

    func run() async throws {
        try await Console.guarded {
            let env = try Environment.load()
            let found: Digest?
            if let date, let edition {
                found = try await env.store.digest(date: date, edition: edition)
            } else if let date {
                found = try await env.store.digest(date: date)
            } else {
                found = try await env.store.latestDigest()
            }
            guard let digest = found else {
                Console.out(date.map { "no digest for \($0)\(edition.map { " edition \($0)" } ?? "")" } ?? "no digest yet")
                return
            }
            if digest.edition > 1, edition == nil {
                Console.err("note: edition \(digest.edition) of \(digest.date); earlier: digest-cli show --date \(digest.date) --edition 1...\(digest.edition - 1)")
            }
            if json {
                Console.out(String(decoding: try Digest.encoder.encode(digest), as: UTF8.self))
            } else {
                Console.out(DigestMarkdown.render(digest, home: env.paths.home))
            }
            // A later run that produced no digest (budget stop, failure) is worth knowing about; stderr keeps --json clean.
            if date == nil, let last = try await env.store.lastRun(), last.id != digest.runID, last.status != .succeeded,
               LocalDate.string(last.startedAt) >= digest.date {
                Console.err("note: run \(last.id) (\(last.status.rawValue)) wrote no digest\(last.errorSummary.map { ": \($0)" } ?? "")")
            }
        }
    }
}

/// Hidden diagnostic: which prompt directory was resolved and what it holds. No network, no API key, no database.
struct PromptsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prompts", abstract: "List loaded prompts and their directory.", shouldDisplay: false)

    func run() async throws {
        try await Console.guarded {
            let config = try Config.load(home: AppPaths.resolve().home)
            let loader = try PromptLoader.bundled(pins: config.promptPins)
            Console.out("directory: \(loader.directory.path)")
            let files = try FileManager.default.contentsOfDirectory(atPath: loader.directory.path)
            let names = Set(files.compactMap { f -> String? in
                guard f.hasSuffix(".md"), let r = f.range(of: ".v", options: .backwards) else { return nil }
                return String(f[..<r.lowerBound])
            })
            for name in names.sorted() {
                let p = try loader.load(name)
                Console.out("\(name) v\(p.version) \(p.model)")
            }
        }
    }
}

struct RecordGolden: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Export a run into the golden layout for prompt evals.")

    @Option(help: "Run id (default: the latest run that reached select).") var runId: String?
    @Option(help: "Golden root directory, e.g. Tests/Fixtures/golden (the default); the <YYYY-MM-DD> day directory is created inside it.")
    var out: String?

    func run() async throws {
        try await Console.guarded {
            let env = try Environment.load()
            var latest: String?
            if runId == nil { latest = try await env.store.latestRun(reaching: .select)?.id }
            guard let id = runId ?? latest else {
                Console.err("error: no run has reached the select stage yet")
                throw ExitCode(1)
            }
            let written = try await Golden.record(store: env.store, runID: id, config: env.config,
                                                  root: URL(fileURLWithPath: out ?? "Tests/Fixtures/golden", isDirectory: true))
            Console.out("recorded run \(id) into \(written.directory.path)")
            if written.keptExistingTriageGolden { Console.out("kept the existing triage_golden.json (hand-edited scores)") }
        }
    }
}

/// The user's home directory (`~/Library/LaunchAgents`, `~/Library/Logs`); `HOME` wins so tests and dry runs can redirect it.
enum UserHome {
    static var url: URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty { return URL(fileURLWithPath: home, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

enum AgentPlanPrinter {
    static func print(_ plan: InstallPlan, dryRun: Bool) {
        for step in plan.steps {
            if dryRun, case let .writeFile(url, contents) = step {
                Console.out("--- \(url.path) ---")
                Console.out(contents.hasSuffix("\n") ? String(contents.dropLast()) : contents)
                Console.out("---")
            }
            Console.out("\(dryRun ? "would run: " : "")\(step)")
        }
        for note in plan.notes { Console.out(note) }
    }
}

struct InstallAgent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Install (or reinstall) the launchd agents.")

    @Flag(help: "Print the rendered plists and the launchctl commands; write and load nothing.") var dryRun = false
    @Option(help: "Path to brainmaxxing.app (default: the bundle containing digest-cli, or one next to it).") var appPath: String?

    func run() async throws {
        try await Console.guarded {
            let config = try Config.load(home: AppPaths.resolve().home)
            guard let exe = AgentInstaller.currentExecutable() else { throw ValidationError("cannot resolve the digest-cli binary path") }
            var app: URL?
            if let appPath {
                let url = URL(fileURLWithPath: appPath, isDirectory: true).standardizedFileURL
                guard FileManager.default.fileExists(atPath: url.path) else { throw SchedulingError.appBundleNotFound(url.path) }
                app = url
            } else {
                app = AgentInstaller.locateApp(executable: exe)
            }
            guard let templates = AgentInstaller.locateTemplates(executable: exe) else { throw SchedulingError.templatesNotFound }
            let launchctl = SystemLaunchctl()
            let plan = try await AgentInstaller.planInstall(cliPath: exe, appPath: app, templates: templates, config: config,
                                                            home: UserHome.url, uid: launchctl.uid, probe: launchctl)
            if !dryRun { try await AgentInstaller.apply(plan, runner: launchctl) }
            AgentPlanPrinter.print(plan, dryRun: dryRun)
            if let next = LaunchAgentPlist.nextFire(hours: plan.runHours, after: Date()) {
                Console.out("\(dryRun ? "next fire after install" : "installed; next fire"): \(next.formatted(date: .abbreviated, time: .shortened))")
            }
        }
    }
}

struct UninstallAgent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Unload and remove the launchd agents.")

    @Flag(help: "Print the launchctl commands and files to remove; change nothing.") var dryRun = false

    func run() async throws {
        try await Console.guarded {
            let launchctl = SystemLaunchctl()
            let plan = await AgentInstaller.planUninstall(home: UserHome.url, uid: launchctl.uid, probe: launchctl)
            if !dryRun { try await AgentInstaller.apply(plan, runner: launchctl) }
            AgentPlanPrinter.print(plan, dryRun: dryRun)
        }
    }
}
