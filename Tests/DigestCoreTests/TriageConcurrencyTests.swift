import Foundation
import Testing
@testable import DigestCore

/// Parks triage calls and releases them in waves: the first call alone, then each time as many calls are waiting as
/// can be in flight (`concurrency`, or fewer near the end). Once opened it lets every call straight through.
actor CallGate {
    let concurrency: Int
    let total: Int
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var released = 0
    private var inFlight = 0
    private var open = false
    private(set) var maxInFlight = 0
    /// "start" when a call arrives, "end" when it is let through.
    private(set) var events: [String] = []

    init(concurrency: Int, total: Int) {
        self.concurrency = concurrency
        self.total = total
    }

    func enter() async {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        events.append("start")
        if open { return finish(1) }
        await withCheckedContinuation { continuation in
            parked.append(continuation)
            let target = released == 0 ? 1 : min(concurrency, total - released)
            if parked.count >= target { releaseParked() }
        }
    }

    func openAll() {
        open = true
        releaseParked()
    }

    private func releaseParked() {
        let waiting = parked
        parked = []
        finish(waiting.count)
        waiting.forEach { $0.resume() }
    }

    private func finish(_ n: Int) {
        released += n
        inFlight -= n
        events += Array(repeating: "end", count: n)
    }
}

/// `MockLLM` behind a `CallGate`; the batch starting with `failFirstID` is refused for budget and opens the gate.
struct GatedLLM: LLMClient {
    let gate: CallGate
    var failFirstID: String?
    let inner = MockLLM { _, ids in scoreAll(ids) }

    var requests: [LLMRequest] { inner.requests }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        await gate.enter()
        if let failFirstID, case let .text(user, _)? = request.messages.first?.content.first, user.contains("\"id\":\"\(failFirstID)\"") {
            await gate.openAll()
            throw LLMError.budgetExceeded(spentUSD: 4, capUSD: 4)
        }
        return try await inner.complete(request)
    }
}

@Suite(.timeLimit(.minutes(1))) struct TriageConcurrencyTests {
    func setUp(_ n: Int) async throws -> (store: Store, papers: [RawPaper]) {
        let store = try tempStore()
        let papers = try (0..<n).map { try samplePaper(String(format: "2610.%05d", $0)) }
        try await store.startRun(id: "r", startedAt: Date(), force: true, since: nil, stages: .all)
        try await store.upsertPapers(papers, runID: "r")
        return (store, papers)
    }

    @Test func firstBatchAloneThenBoundedInFlight() async throws {
        let (store, papers) = try await setUp(250)  // 10 batches
        let gate = CallGate(concurrency: 3, total: 10)
        let llm = GatedLLM(gate: gate)
        let outcome = try await Triage.run(papers: papers, prompt: try testTriagePrompt(), config: Config(triageConcurrency: 3), llm: llm,
                                           store: store, runID: "r")
        #expect(llm.requests.count == 10)
        #expect(outcome.scores.count == 250 && !outcome.partial)
        #expect(outcome.scores.map(\.paperID) == papers.map(\.id))
        #expect(await gate.maxInFlight == 3)
        let events = await gate.events
        #expect(Array(events.prefix(3)) == ["start", "end", "start"])  // the first call finished before the second began
    }

    @Test func budgetStopsSchedulingAndKeepsInFlightResults() async throws {
        let (store, papers) = try await setUp(250)
        let gate = CallGate(concurrency: 3, total: 10)
        // The second batch, launched in the first concurrent wave, is refused.
        let llm = GatedLLM(gate: gate, failFirstID: "2610.00025")
        let outcome = try await Triage.run(papers: papers, prompt: try testTriagePrompt(), config: Config(triageConcurrency: 3), llm: llm,
                                           store: store, runID: "r")
        let calls = llm.requests.count + 1  // the refused call never reaches the inner mock
        // First batch, the wave of 3, plus at most one launch per success received before the refusal.
        #expect((4...6).contains(calls))
        #expect(outcome.scores.count == (calls - 1) * 25)
        #expect(try await store.rankedPapers(runID: "r").count == outcome.scores.count)
        #expect(!outcome.scores.contains { $0.paperID == "2610.00025" })
        #expect(outcome.partial)
        #expect(outcome.error as? LLMError == .budgetExceeded(spentUSD: 4, capUSD: 4))
    }

    @Test func concurrentRunMatchesSequentialRun() async throws {
        func triage(concurrency: Int) async throws -> (outcome: TriageOutcome, calls: Int) {
            let (store, papers) = try await setUp(130)
            // One paper is left out by the model; the batch holding 2610.00060 is cut off by max_tokens and split.
            let llm = MockLLM(stopReason: { $0.contains("2610.00060") && $0.count > 11 ? "max_tokens" : "tool_use" },
                              respond: { _, ids in TriageResult(results: scoreAll(ids).results.filter { $0.id != "2610.00007" }) })
            let outcome = try await Triage.run(papers: papers, prompt: try testTriagePrompt(), config: Config(triageConcurrency: concurrency),
                                               llm: llm, store: store, runID: "r")
            return (outcome, llm.requests.count)
        }
        let sequential = try await triage(concurrency: 1)
        let concurrent = try await triage(concurrency: 4)
        #expect(sequential.outcome.scores.count == 117)  // 130 - 1 left out - 12 in the half still cut off
        #expect(concurrent.outcome.scores == sequential.outcome.scores)
        #expect(concurrent.outcome.unscored == sequential.outcome.unscored)
        #expect(concurrent.calls == sequential.calls)
    }
}
