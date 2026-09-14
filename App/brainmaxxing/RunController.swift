import DigestCore
import Foundation
import Observation

enum RunControllerError: LocalizedError {
    case cliMissing(String)

    var errorDescription: String? {
        switch self {
        case let .cliMissing(path): "digest-cli is not bundled at \(path)"
        }
    }
}

/// Runs the bundled `digest-cli` as a child process and exposes its progress.
/// Progress comes from two places: the CLI's stdout/stderr lines, and the run row's counts, which the pipeline
/// updates after fetch, triage and select; the CLI itself prints only at the end.
@Observable @MainActor
final class RunController {
    private(set) var isRunning = false
    private(set) var startedAt: Date?
    /// Last non-empty output line.
    private(set) var lastLine: String?
    /// Output of the current or last run, capped.
    private(set) var output: [String] = []
    /// "fetched 431, new 398, triaged 120, selected 15", from the run row.
    private(set) var progress: String?
    private(set) var lastExitStatus: Int32?

    private var process: Process?
    private var pollTask: Task<Void, Never>?

    /// `Contents/MacOS/digest-cli`, next to the app binary.
    static var cliURL: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("digest-cli")
    }

    static func arguments(categories: [String]?) -> [String] {
        var args = ["run", "--force"]
        if let categories, !categories.isEmpty { args += ["--categories", categories.joined(separator: ",")] }
        return args
    }

    func start(categories: [String]?, store: Store?, onExit: @escaping @MainActor () async -> Void) throws {
        guard !isRunning else { return }
        guard let cli = Self.cliURL, FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw RunControllerError.cliMissing(Self.cliURL?.path ?? "Contents/MacOS/digest-cli")
        }
        let process = Process()
        let arguments = Self.arguments(categories: categories)
        process.executableURL = cli
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in await self?.finish(status: status, onExit: onExit) }
        }
        output = ["$ digest-cli " + arguments.joined(separator: " ")]
        lastLine = "Starting..."
        progress = nil
        lastExitStatus = nil
        try process.run()
        self.process = process
        isRunning = true
        startedAt = Date()

        let handle = pipe.fileHandleForReading
        Task {
            do {
                for try await line in handle.bytes.lines { self.append(line) }
            } catch {
                self.append("(output stream closed: \(error.localizedDescription))")
            }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll(store: store)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Stops a running pipeline (SIGTERM). What the run already stored stays.
    func cancel() {
        process?.terminate()
    }

    private func append(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        output.append(trimmed)
        if output.count > 500 { output.removeFirst(output.count - 500) }
        lastLine = trimmed
    }

    private func poll(store: Store?) async {
        guard let store, let started = startedAt, let run = try? await store.lastRun(), run.startedAt >= started.addingTimeInterval(-5)
        else { return }
        progress = Self.describe(run)
    }

    private func finish(status: Int32, onExit: @MainActor () async -> Void) async {
        pollTask?.cancel()
        pollTask = nil
        process = nil
        isRunning = false
        lastExitStatus = status
        if status != 0 { lastLine = "digest-cli exited with status \(status)" + (lastLine.map { ": \($0)" } ?? "") }
        await onExit()
    }

    static func describe(_ run: RunRecord) -> String {
        let c = run.counts
        var parts = ["fetched \(c.fetched)", "new \(c.new)", "triaged \(c.triaged)", "selected \(c.selected)"]
        if c.fulltext > 0 { parts.append("full text \(c.fulltext)") }
        if let stage = run.lastStage { parts.insert("done: \(stage.rawValue)", at: 0) }
        return parts.joined(separator: ", ")
    }
}
