import Foundation
import Synchronization
import Testing
@testable import DigestCore

// MARK: Helpers

/// The canned `digest` tool input (`Fixtures/digest/tool-call.json`).
func cannedDigestInput() throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: try TestSupport.fixture("digest/tool-call.json"))
}

/// Minimal structural check against a strict JSON schema: types, `required` == all keys, no extra keys.
func conforms(_ value: JSONValue, to schema: JSONValue, path: String = "$") -> [String] {
    switch (schema["type"]?.stringValue, value) {
    case let ("object", .object(object)):
        guard case let .object(properties)? = schema["properties"] else { return ["\(path): schema without properties"] }
        var issues: [String] = []
        var required = Set<String>()
        if case let .array(a)? = schema["required"] { required = Set(a.compactMap(\.stringValue)) }
        if required != Set(properties.keys) { issues.append("\(path): required != properties") }
        if Set(object.keys) != Set(properties.keys) { issues.append("\(path): keys \(object.keys.sorted()) != \(properties.keys.sorted())") }
        for (key, sub) in properties { if let v = object[key] { issues += conforms(v, to: sub, path: "\(path).\(key)") } }
        return issues
    case let ("array", .array(items)):
        guard let itemSchema = schema["items"] else { return ["\(path): no items schema"] }
        return items.enumerated().flatMap { conforms($1, to: itemSchema, path: "\(path)[\($0)]") }
    case ("string", .string), ("boolean", .bool): return []
    case let ("integer", .number(n)): return n == n.rounded() ? [] : ["\(path): not an integer"]
    default: return ["\(path): expected \(schema["type"]?.stringValue ?? "?")"]
    }
}

/// Triage answers like `MockLLM` (score = last digit); digest requests go to `digest`.
final class StagedLLM: LLMClient {
    let triage = MockLLM { _, ids in scoreAll(ids) }
    private let digestRequests = Mutex<[LLMRequest]>([])
    private let digest: @Sendable (_ index: Int, _ request: LLMRequest) throws -> LLMResponse
    /// When set, digest responses are billed into `llm_calls` like `AnthropicClient` does.
    let meter: CostMeter?

    init(meter: CostMeter? = nil, digest: @escaping @Sendable (_ index: Int, _ request: LLMRequest) throws -> LLMResponse = { _, r in try StagedLLM.canned(r) }) {
        self.digest = digest
        self.meter = meter
    }

    var digestCalls: [LLMRequest] { digestRequests.withLock { $0 } }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        guard request.stage == .digest else { return try await triage.complete(request) }
        let index = digestRequests.withLock { $0.append(request); return $0.count - 1 }
        let response = try digest(index, request)
        try await meter?.record(usage: response.usage, model: request.model, stage: .digest, promptName: request.promptName,
                                promptVersion: request.promptVersion, runID: RunContext.runID)
        return response
    }

    static func canned(_ request: LLMRequest, stopReason: String = "tool_use") throws -> LLMResponse {
        LLMResponse(content: [.text("Here it is.", cache: false), .toolUse(id: "toolu_d", name: "digest", input: try cannedDigestInput())],
                    stopReason: stopReason, usage: LLMUsage(inputTokens: 5000, outputTokens: 3000), model: request.model)
    }
}

/// Full text for `2610.00019` (one figure); every other paper fails like a 500 would.
struct FakeFullText: FullTextFetcher {
    func fetch(_ paper: RawPaper) async throws -> FullTextResult {
        guard paper.id == "2610.00019" else { throw FullTextError.http(status: 500, url: paper.id) }
        return FullTextResult(text: "# Title\n\nBody of the paper.\n\n[Figure 1: Overview]",
                              figures: [(try TestSupport.fixture("fulltext/2610.28632v1.fig1.png"), "Overview of the method.")], source: .html)
    }
}

/// The real digest prompt + schema next to the test triage prompt (prompts are files, even in tests).
func testPromptDirectory() throws -> URL {
    let dir = try testTriagePromptDirectory()
    let bundled = try PromptLoader.bundled().directory
    try FileManager.default.copyItem(at: bundled.appendingPathComponent("digest.v1.md"), to: dir.appendingPathComponent("digest.v1.md"))
    try FileManager.default.copyItem(at: bundled.appendingPathComponent("schemas/digest.json"), to: dir.appendingPathComponent("schemas/digest.json"))
    return dir
}

let digestPaperIDs = ["2610.00019", "2610.00028", "2610.00037", "2610.00041"]  // scores 9, 8, 7, 1

func digestPapers() throws -> [RawPaper] {
    try digestPaperIDs.map { id in
        var p = try samplePaper(id, title: "Paper \(id)")
        p.published = Date().addingTimeInterval(-86_400)
        p.authors = (1...8).map { "Author \($0)" }
        return p
    }
}

// MARK: Writer

@Suite struct DigestWriterTests {
    func bundlePapers() throws -> [BundlePaper] {
        let papers = try digestPapers()
        let fig = Figure(paperID: papers[0].id, index: 1, path: "figures/\(papers[0].id)/1.png", caption: "Overview of the method.", source: .html)
        return [
            BundlePaper(ranked: RankedPaper(paper: papers[0], score: 9, oneLine: "why 1", tags: ["rl", "agents"], selected: true, rank: 1),
                        fullText: "Body.", source: .html, figures: [fig]),
            BundlePaper(ranked: RankedPaper(paper: papers[1], score: 8, oneLine: "why 2", tags: [], selected: true, rank: 2),
                        fullText: nil, source: nil, figures: [fig]),
            BundlePaper(ranked: RankedPaper(paper: papers[2], score: 7, oneLine: "why 3", tags: ["x\"y"], selected: true, rank: 3),
                        fullText: nil, source: nil, figures: []),
        ]
    }

    @Test func cannedToolCallConformsToSchema() throws {
        let schema = try #require(try PromptLoader.bundled().load("digest").schema)
        #expect(conforms(try cannedDigestInput(), to: schema) == [])
    }

    @Test func bundleLayout() throws {
        let papers = try bundlePapers()
        let bundle = DigestWriter.bundle(date: "2026-10-21", partial: false, recentClusters: [], papers: papers)
        let published = LocalDate.string(papers[0].ranked.paper.published, calendar: { var c = Calendar(identifier: .gregorian); c.timeZone = .gmt; return c }())
        #expect(bundle.hasPrefix("""
            <run date="2026-10-21" selected="3" partial="false">
            <recent_clusters>
            (none yet)
            </recent_clusters>
            <papers>
            <paper id="2610.00019" rank="1" score="9" tags="rl, agents" primary_category="cs.LG" fulltext="html" chars="5">
            <title>Paper 2610.00019</title>
            <authors>Author 1, Author 2, Author 3, Author 4, Author 5, Author 6 et al.</authors>
            <published>\(published)</published>
            <triage>why 1</triage>
            <abstract>An abstract.</abstract>
            <figures>
            <figure index="1">Overview of the method.</figure>
            </figures>
            <fulltext>
            Body.
            </fulltext>
            </paper>
            <paper id="2610.00028" rank="2" score="8" tags="" primary_category="cs.LG" fulltext="none" chars="0">
            """))
        // fulltext="none": no <fulltext>, empty <figures> even when figures are passed.
        #expect(bundle.contains("<figures>\n</figures>\n</paper>\n<paper id=\"2610.00037\""))
        #expect(bundle.contains("tags=\"x&quot;y\""))
        #expect(bundle.hasSuffix("</papers>\n<hf_papers>\n(none)\n</hf_papers>\n</run>"))
        let recent = DigestWriter.bundle(date: "2026-10-21", partial: true, recentClusters: ["A", "B"], papers: [])
        #expect(recent.hasPrefix("<run date=\"2026-10-21\" selected=\"0\" partial=\"true\">\n<recent_clusters>\nA\nB\n</recent_clusters>"))
    }

    @Test func normalizeEnforcesContract() throws {
        let papers = try bundlePapers()
        let out = try JSONDecoder().decode(DigestToolOutput.self, from: try TestSupport.fixture("digest/tool-call.json"))
        let (clusters, result) = DigestWriter.normalize(out, papers: papers)
        // Unknown id dropped; the second cluster loses 2610.00019 (first wins) and is dissolved.
        #expect(clusters == [DigestCluster(id: "c1", name: "Video-motion co-generation", paperIDs: ["2610.00019", "2610.00028"],
                                           narrative: out.clusters[0].narrative)])
        #expect(result.map(\.id) == ["2610.00019", "2610.00028", "2610.00037"])  // rank order, unknown id dropped
        #expect(result.map(\.clusterID) == ["c1", "c1", ""])                     // derived from clusters, not the model
        #expect(result[0].essence == "First paper essence.")
        #expect(result[0].mermaid == "flowchart LR\n  A[\"rig\"] --> B[\"motion DiT\"]\n  B --> C[\"video\"]")
        #expect(result[0].figureIndex == 1 && result[0].figure?.caption == "Overview of the method.")
        #expect(result[1].figureIndex == 0 && result[1].figure == nil)          // index 2 does not exist
        #expect(result[2].modelOmitted && result[2].essence == "why 3" && result[2].detail.isEmpty)
        #expect(!result[0].modelOmitted)
        #expect(result[0].links == PaperLinks(abs: URL(string: "https://arxiv.org/abs/2610.00019v1"),
                                              html: URL(string: "https://arxiv.org/html/2610.00019v1"),
                                              pdf: URL(string: "https://arxiv.org/pdf/2610.00019v1")))
        #expect(result[0].authors.count == 8)
    }

    @Test func requestShape() throws {
        let prompt = try PromptLoader.bundled().load("digest")
        let r = try DigestWriter.request(prompt: prompt, system: "sys", bundle: "<run/>", model: "claude-opus-5-5")
        #expect(r.maxTokens == 64000)
        #expect(r.toolChoice == .auto)
        #expect(r.tools.first?.strict == true && r.tools.first?.name == "digest")
        #expect(r.system == [LLMTextBlock(text: "sys", cache: true)])
        #expect(r.messages.first?.content == [.text("<run/>", cache: true), .text(DigestWriter.instruction, cache: false)])
        let body = try #require(try JSONSerialization.jsonObject(with: AnthropicClient.encodeBody(r)) as? [String: Any])
        #expect(body["stream"] as? Bool == true)
        #expect(body["thinking"] == nil && body["temperature"] == nil)
    }

    @Test func retriesOnceWithoutToolCallThenFails() async throws {
        let prompt = try PromptLoader.bundled().load("digest")
        let request = try DigestWriter.request(prompt: prompt, system: "sys", bundle: "<run/>", model: "claude-opus-5-5")
        let prose = StagedLLM { _, r in LLMResponse(content: [.text("Prose instead.", cache: false)], stopReason: "end_turn",
                                                    usage: LLMUsage(inputTokens: 1, outputTokens: 1), model: r.model) }
        await #expect(throws: DigestError.noToolCall) { try await DigestWriter.call(request, toolName: "digest", llm: prose) }
        #expect(prose.digestCalls.count == 2)
        let retry = try #require(prose.digestCalls.last)
        #expect(retry.messages.count == 3)
        #expect(retry.messages[1] == LLMMessage(role: .assistant, content: [.text("Prose instead.", cache: false)]))
        #expect(retry.messages[2] == LLMMessage(role: .user, content: [.text(DigestWriter.retryInstruction, cache: false)]))
        #expect(retry.messages[0] == request.messages[0])  // cached bundle prefix unchanged

        let secondTime = StagedLLM { i, r in
            i == 0 ? LLMResponse(content: [], stopReason: "end_turn", usage: LLMUsage(inputTokens: 1, outputTokens: 1), model: r.model)
                : try StagedLLM.canned(r)
        }
        #expect(try await DigestWriter.call(request, toolName: "digest", llm: secondTime).title == "Rigs, motion and the cost of coupling")
        #expect(secondTime.digestCalls.last?.messages.count == 2)  // no empty assistant turn

        let truncated = StagedLLM { _, r in try StagedLLM.canned(r, stopReason: "max_tokens") }
        await #expect(throws: DigestError.outputTruncated) { try await DigestWriter.call(request, toolName: "digest", llm: truncated) }
        #expect(truncated.digestCalls.count == 1)  // no automatic retry
    }
}

// MARK: End to end

@Suite struct DigestPipelineTests {
    func pipeline(_ store: Store, _ llm: LLMClient, papers: [RawPaper]? = nil, config: Config = Config()) throws -> Pipeline {
        Pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: try papers ?? digestPapers())], llm: llm,
                 prompts: PromptLoader(directory: try testPromptDirectory()), config: config, fullText: FakeFullText())
    }

    @Test func runStoresDigestAndShowsIt() async throws {
        let store = try tempStore()
        let llm = StagedLLM(meter: CostMeter(store: store, dailyBudgetUSD: 4))
        let report = try await pipeline(store, llm).run(force: true)
        #expect(!report.partial, "\(report.errors)")
        #expect(report.counts.selected == 3)
        #expect(report.counts.fulltext == 1)
        #expect(report.counts.written == 2)
        #expect(llm.digestCalls.count == 1)

        let today = LocalDate.string(Date())
        let digest = try #require(try await store.digest(date: today))
        #expect(digest == (try await store.latestDigest()))
        #expect(digest.runID == report.runID && !digest.partial && !digest.empty)
        #expect(digest.promptVersion == 1 && digest.model == "claude-opus-5-5")
        #expect(abs(digest.costUSD - 0.08) < 1e-9)  // 5000 in x $4 + 3000 out x $20 per 1M
        #expect(report.costByStage[.digest] == digest.costUSD)
        #expect(digest.papers.map(\.id) == ["2610.00019", "2610.00028", "2610.00037"])
        let figure = try #require(digest.papers[0].figure)
        #expect(figure.path == "figures/2610.00019/1.png")
        #expect(FileManager.default.fileExists(atPath: store.home.appendingPathComponent(figure.path).path))
        #expect(try await store.fullText(paperID: "2610.00019")?.contains("Body of the paper.") == true)

        // The bundle the model saw: full text for one paper, abstract-only for the others.
        let bundle = try #require(llm.digestCalls.first.flatMap { r -> String? in
            if case let .text(t, true)? = r.messages.first?.content.first { return t } else { return nil } })
        #expect(bundle.contains("<paper id=\"2610.00019\" rank=\"1\" score=\"9\" tags=\"tag\" primary_category=\"cs.LG\" fulltext=\"html\""))
        #expect(bundle.contains("<paper id=\"2610.00028\" rank=\"2\" score=\"8\" tags=\"tag\" primary_category=\"cs.LG\" fulltext=\"none\" chars=\"0\">"))
        #expect(!bundle.contains("2610.00041"))

        let markdown = DigestMarkdown.render(digest, home: store.home)
        #expect(markdown.contains("# Rigs, motion and the cost of coupling"))
        #expect(markdown.contains("## Video-motion co-generation"))
        #expect(markdown.contains("[2610.00019](https://arxiv.org/abs/2610.00019v1) and [2610.00028](https://arxiv.org/abs/2610.00028v1)"))
        #expect(markdown.contains("```mermaid\nflowchart LR"))

        let run = try #require(try await store.lastRun())
        #expect(run.status == .succeeded && run.lastStage == .digest)
        #expect(run.promptVersions == ["triage": 1, "digest": 1])
        // Done today: a second unforced run is refused.
        await #expect(throws: PipelineError.self) { try await pipeline(store, llm).run(force: false) }
        // A forced re-run the same day selects nothing new (all three were shown) -> no edition 2, the digest stays.
        let again = try await pipeline(store, llm).run(force: true)
        #expect(again.counts.selected == 0 && again.counts.written == 0 && !again.partial)
        #expect(llm.digestCalls.count == 1)
        #expect(try await store.digest(date: today) == digest)
        #expect(try await store.digestList().map(\.edition) == [1])
        // A forced re-run that finds an unshown paper >= min_score writes edition 2 with only that paper; edition 1 stays.
        var extra = try samplePaper("2610.00058", title: "Paper 2610.00058")
        extra.published = Date().addingTimeInterval(-3600)
        let third = try await pipeline(store, llm, papers: try digestPapers() + [extra]).run(force: true)
        #expect(third.counts.selected == 1)
        let second = try #require(try await store.digest(date: today))
        #expect(second.edition == 2 && second.runID == third.runID && second.papers.map(\.id) == ["2610.00058"])
        #expect(try await store.digest(date: today, edition: 1) == digest)
        #expect(try await store.digestList().map(\.id) == ["\(today)#2", today])
    }

    /// Only deterministic digest failures block a same-day unforced retry, and only until a later transient one.
    @Test func digestFailureKindDecidesSameDayRetry() async throws {
        #expect(Pipeline.isDeterministic(DigestError.outputTruncated) && Pipeline.isDeterministic(DigestError.noToolCall))
        #expect(Pipeline.isDeterministic(LLMError.invalidToolInput("digest", "x")))
        #expect(!Pipeline.isDeterministic(LLMError.streamError(type: nil, message: "x")))
        #expect(!Pipeline.isDeterministic(LLMError.http(status: 529, type: nil, message: "x")))
        #expect(!Pipeline.isDeterministic(LLMError.budgetExceeded(spentUSD: 4, capUSD: 4)))

        let store = try tempStore()
        let overloaded = StagedLLM { _, _ in throw LLMError.streamError(type: "overloaded_error", message: "Overloaded") }
        _ = try await pipeline(store, overloaded).run(force: false)
        #expect(try await store.deterministicDigestFailure(onDayOf: Date()) == nil)
        _ = try await pipeline(store, overloaded).run(force: false)
        #expect(overloaded.digestCalls.count == 2)  // transient: retried

        let truncated = StagedLLM { _, r in try StagedLLM.canned(r, stopReason: "max_tokens") }
        let failed = try await pipeline(store, truncated).run(force: false)
        #expect(try await store.deterministicDigestFailure(onDayOf: Date())?.id == failed.runID)
        // A forced run still tries; its transient failure lifts the block.
        _ = try await pipeline(store, overloaded).run(force: true)
        #expect(overloaded.digestCalls.count == 3)
        #expect(try await store.deterministicDigestFailure(onDayOf: Date()) == nil)
    }

    @Test func budgetStopBeforeDigestKeepsRankedListThenRerunDigest() async throws {
        let store = try tempStore()
        let stopping = StagedLLM { _, _ in throw LLMError.budgetExceeded(spentUSD: 3.9, capUSD: 4) }
        let report = try await pipeline(store, stopping).run(force: true)
        #expect(report.partial)
        #expect(report.errors[.digest] as? LLMError == .budgetExceeded(spentUSD: 3.9, capUSD: 4))
        #expect(report.errors[.triage] == nil)
        #expect(try await store.latestDigest() == nil)
        let ranked = try await store.rankedPapers(runID: report.runID, selectedOnly: true)
        #expect(ranked.map(\.paper.id) == ["2610.00019", "2610.00028", "2610.00037"])
        let run = try #require(try await store.lastRun())
        #expect(run.status == .partial && run.lastStage == .fulltext && run.errors[.digest] != nil)
        #expect(try await store.lastSuccessfulRun(reaching: Pipeline.completionStage) == nil)

        // `run --stage digest`: same run id, no triage, digest stored, run succeeds.
        let llm = StagedLLM()
        let rerun = try await pipeline(store, llm).rerunDigest()
        #expect(rerun.runID == report.runID)
        #expect(!rerun.partial && rerun.errors.isEmpty)
        #expect(llm.triage.requests.isEmpty && llm.digestCalls.count == 1)
        #expect(try await store.latestDigest()?.runID == report.runID)
        let after = try #require(try await store.run(id: report.runID))
        #expect(after.status == .succeeded && after.lastStage == .digest && after.errors.isEmpty)
    }

    @Test func noToolCallLeavesRunPartial() async throws {
        let store = try tempStore()
        let prose = StagedLLM { _, r in LLMResponse(content: [.text("no", cache: false)], stopReason: "end_turn",
                                                    usage: LLMUsage(inputTokens: 1, outputTokens: 1), model: r.model) }
        let report = try await pipeline(store, prose).run(force: true)
        #expect(report.partial && report.errors[.digest] as? DigestError == .noToolCall)
        #expect(try await store.rankedPapers(runID: report.runID, selectedOnly: true).count == 3)
    }

    @Test func bundleBytesIdenticalAcrossBuilds() async throws {
        let store = try tempStore()
        let llm = StagedLLM()
        let report = try await pipeline(store, llm).run(force: true, stages: Stage.fulltext.throughHere)
        let p = try pipeline(store, llm)
        let selected = try await store.rankedPapers(runID: report.runID, selectedOnly: true)
        let a = DigestWriter.bundle(date: "2026-10-21", partial: false, recentClusters: ["x"], papers: try await p.bundlePapers(selected))
        let b = DigestWriter.bundle(date: "2026-10-21", partial: false, recentClusters: ["x"], papers: try await p.bundlePapers(selected))
        #expect(Data(a.utf8) == Data(b.utf8))
        #expect(a.contains("fulltext=\"html\""))
        #expect(llm.digestCalls.isEmpty)
    }

    @Test func emptyDayWritesNothingNewWithoutLLMCall() async throws {
        let store = try tempStore()
        let llm = StagedLLM()
        let low = try digestPapers().filter { $0.id == "2610.00041" }
        var config = Config()
        config.language = "en"
        let report = try await pipeline(store, llm, papers: low, config: config).run(force: true)
        #expect(!report.partial && report.counts.selected == 0)
        #expect(llm.digestCalls.isEmpty)
        let digest = try #require(try await store.latestDigest())
        #expect(digest.empty && digest.title == "Nothing new" && digest.promptVersion == nil)
        #expect(digest.summary.contains("fetched 1"))
        #expect(try await store.lastSuccessfulRun(reaching: Pipeline.completionStage)?.id == report.runID)
    }

    @Test func unshownPapersCarryOverToTheNextRun() async throws {
        let store = try tempStore()
        // Run 1 scores everything but its digest fails: nothing was shown.
        let failing = StagedLLM { _, _ in throw LLMError.http(status: 500, type: nil, message: "x") }
        let first = try await pipeline(store, failing).run(force: true)
        #expect(first.partial)
        // Run 2 fetches nothing new; the pool still holds run 1's papers, which compete again and are marked as carried over.
        let llm = StagedLLM()
        let second = try await pipeline(store, llm, papers: []).run(force: true)
        #expect(second.counts.new == 0 && second.counts.selected == 3)
        let ranked = try await store.rankedPapers(runID: second.runID, selectedOnly: true)
        #expect(ranked.allSatisfy { $0.scoredInRunID == first.runID })
        #expect(try await store.latestDigest()?.papers.count == 3)
    }
}

@Suite struct GoldenTests {
    @Test func recordGoldenWritesLayoutAndKeepsHandEdits() async throws {
        let store = try tempStore()
        let pipeline = Pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: try digestPapers())], llm: StagedLLM(),
                                prompts: PromptLoader(directory: try testPromptDirectory()), config: Config(), fullText: FakeFullText())
        let report = try await pipeline.run(force: true)
        let root = try TestSupport.tempDirectory()
        let written = try await Golden.record(store: store, runID: report.runID, config: Config(), root: root)
        let dir = written.directory
        #expect(!written.keptExistingTriageGolden)
        let papers = try Golden.decoder.decode([RawPaper].self, from: Data(contentsOf: dir.appendingPathComponent("papers.json")))
        #expect(papers.map(\.id) == digestPaperIDs)
        let triage = try Golden.decoder.decode([Golden.TriageEntry].self, from: Data(contentsOf: dir.appendingPathComponent("triage_golden.json")))
        #expect(triage.map(\.score) == [9, 8, 7, 1])
        #expect(triage.allSatisfy { $0.oneLine?.isEmpty == false && $0.tags != nil })
        // Files without the optional one_line / tags (older or hand-made) still decode.
        let bare = try Golden.decoder.decode([Golden.TriageEntry].self, from: Data(#"[{"id":"x","score":3}]"#.utf8))
        #expect(bare == [Golden.TriageEntry(id: "x", score: 3)])
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: dir.appendingPathComponent("selected.json")))
            == ["2610.00019", "2610.00028", "2610.00037"])
        #expect(try String(contentsOf: dir.appendingPathComponent("fulltext/2610.00019.txt"), encoding: .utf8).contains("Body of the paper."))
        let figures = try JSONDecoder().decode([Golden.FigureEntry].self, from: Data(contentsOf: dir.appendingPathComponent("figures.json")))
        #expect(figures == [Golden.FigureEntry(paperID: "2610.00019", index: 1, caption: "Overview of the method.")])
        #expect(try JSONDecoder().decode(Golden.DayConfig.self, from: Data(contentsOf: dir.appendingPathComponent("config.json"))).topN == 15)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("digest_golden.json").path))

        try Data("[]".utf8).write(to: dir.appendingPathComponent("triage_golden.json"))
        #expect(try await Golden.record(store: store, runID: report.runID, config: Config(), root: root).keptExistingTriageGolden)
        #expect(try String(contentsOf: dir.appendingPathComponent("triage_golden.json"), encoding: .utf8) == "[]")
    }
}
