import Foundation
import os

/// Reports where a run is: every report is one `runs.progress` write plus the caller's callback.
/// One per run; `Pipeline` binds it to `RunContext.progress` so layers below it (the arXiv page loop) can report
/// without the run id in their signatures. A failed write is logged and never fails the run.
actor ProgressReporter {
    private let store: Store
    private let runID: String
    private let onProgress: (@Sendable (RunProgress) -> Void)?
    private var fetchSources: [SourceID] = []
    /// Papers kept so far per source; sources run in parallel, so fetch reports sum across them.
    private var kept: [SourceID: Int] = [:]
    private static let log = Logger(subsystem: "com.brainmaxxing", category: "pipeline")

    init(store: Store, runID: String, onProgress: (@Sendable (RunProgress) -> Void)?) {
        self.store = store
        self.runID = runID
        self.onProgress = onProgress
    }

    func report(_ progress: RunProgress) async {
        do {
            try await store.updateRunProgress(runID, progress: progress)
        } catch {
            Self.log.error("cannot store run progress: \(error.localizedDescription, privacy: .public)")
        }
        onProgress?(progress)
    }

    func fetchStarted(_ sources: [SourceID]) async {
        fetchSources = sources
        kept = [:]
        await report(fetchProgress())
    }

    /// `count` = papers `source` has kept so far; an unchanged count is not reported again.
    func fetched(_ source: SourceID, kept count: Int) async {
        guard kept[source] != count else { return }
        kept[source] = count
        await report(fetchProgress())
    }

    private func fetchProgress() -> RunProgress {
        let names = fetchSources.map(Self.displayName).joined(separator: ", ")
        return RunProgress(stage: .fetch, done: kept.values.reduce(0, +), topic: names.isEmpty ? nil : names)
    }

    static func displayName(_ source: SourceID) -> String {
        switch source {
        case .arxiv: "arXiv"
        case .openalex: "OpenAlex"
        case .hfPapers: "HF Papers"
        }
    }
}
