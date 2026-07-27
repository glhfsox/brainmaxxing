import Foundation
import os

/// USD per 1M tokens.
public struct ModelPricing: Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    /// Prompts longer than this are billed at a different rate; the meter refuses them instead of guessing.
    public var flatRateMaxPromptTokens: Int?

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double, flatRateMaxPromptTokens: Int? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.flatRateMaxPromptTokens = flatRateMaxPromptTokens
    }

    public static let table: [String: ModelPricing] = [
        "claude-haiku-5-5": ModelPricing(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125, flatRateMaxPromptTokens: 100_000),
        "claude-sonnet-5-5": ModelPricing(input: 2.00, output: 10.00, cacheRead: 0.20, cacheWrite: 2.50),
        "claude-opus-5-5": ModelPricing(input: 4.00, output: 20.00, cacheRead: 0.20, cacheWrite: 5.00),
    ]

    public func usd(_ u: LLMUsage) -> Double {
        (Double(u.inputTokens) * input + Double(u.outputTokens) * output
            + Double(u.cacheReadTokens) * cacheRead + Double(u.cacheWriteTokens) * cacheWrite) / 1_000_000
    }
}

/// Enforces the daily budget before each LLM call and records every call's usage into `llm_calls`.
/// "Spent today" is read from the store, so separate processes on the same day share the cap. Within one process, share
/// one instance between concurrent callers (pipeline, chat sessions): each authorized call holds its worst case as an
/// in-flight reservation until `release`, so two callers can't both pass within one worst case of the cap.
public actor CostMeter {
    /// An authorized call's worst case, held until the caller releases it after recording (or failing).
    public struct Reservation: Sendable, Hashable {
        fileprivate let id: UInt64
    }

    private let store: Store
    private let dailyBudgetUSD: Double
    private let pricing: [String: ModelPricing]
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private var reserved: [UInt64: Double] = [:]
    private var nextReservationID: UInt64 = 0
    /// Bumped on every release, so `authorize` can tell its read of the store raced one.
    private var releaseCount: UInt64 = 0
    private static let log = Logger(subsystem: "com.brainmaxxing", category: "cost")

    public init(store: Store, dailyBudgetUSD: Double, pricing: [String: ModelPricing] = ModelPricing.table,
                now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current) {
        self.store = store
        self.dailyBudgetUSD = dailyBudgetUSD
        self.pricing = pricing
        self.now = now
        self.calendar = calendar
    }

    public func price(for model: String) throws -> ModelPricing {
        guard let p = pricing[model] else { throw LLMError.unknownModelPricing(model) }
        return p
    }

    public func spentToday() async throws -> Double {
        try await store.costSince(calendar.startOfDay(for: now()))
    }

    /// USD held by authorized calls that have not been released yet.
    public var inFlightUSD: Double { reserved.values.reduce(0, +) }

    /// Throws `budgetExceeded` unless today's spend plus every in-flight reservation plus this call's worst case (every
    /// prompt token at `max(input, cacheWrite)`, `maxOutputTokens` generated) stays within the cap. On success the worst
    /// case is reserved; the caller must `release` it once the call is recorded or has failed.
    @discardableResult
    public func authorize(model: String, estimatedPromptTokens: Int, maxOutputTokens: Int) async throws -> Reservation {
        let p = try price(for: model)
        if let limit = p.flatRateMaxPromptTokens, estimatedPromptTokens > limit {
            throw LLMError.promptTooLongForPricing(model: model, estimatedTokens: estimatedPromptTokens)
        }
        let worstCase = (Double(estimatedPromptTokens) * max(p.input, p.cacheWrite) + Double(maxOutputTokens) * p.output) / 1_000_000
        var spent: Double
        repeat {
            // A release during the read may have dropped a reservation whose row the read missed: read again.
            let releases = releaseCount
            spent = try await spentToday()
            if releases == releaseCount { break }
        } while true
        // No suspension from here on: the check and the reservation are atomic on the actor.
        if spent + inFlightUSD + worstCase > dailyBudgetUSD {
            throw LLMError.budgetExceeded(spentUSD: spent + inFlightUSD, capUSD: dailyBudgetUSD)
        }
        nextReservationID += 1
        reserved[nextReservationID] = worstCase
        return Reservation(id: nextReservationID)
    }

    /// Drops an authorized call's reservation. Call after its usage is recorded, or when it failed unbilled. Idempotent.
    public func release(_ reservation: Reservation) {
        guard reserved.removeValue(forKey: reservation.id) != nil else { return }
        releaseCount += 1
    }

    /// Records one completed call; returns its USD estimate. `estimated`: `usage` is a worst case, not what the API reported.
    @discardableResult
    public func record(usage: LLMUsage, model: String, stage: Stage, promptName: String?, promptVersion: Int?, runID: String?,
                       estimated: Bool = false) async throws -> Double {
        let p = try price(for: model)
        let promptTokens = usage.inputTokens + usage.cacheReadTokens + usage.cacheWriteTokens
        if let limit = p.flatRateMaxPromptTokens, promptTokens > limit {
            Self.log.fault("prompt of \(promptTokens) tokens exceeded flat-rate tier of \(model, privacy: .public); estimate is low")
        }
        let usd = p.usd(usage)
        let record = LLMCallRecord(
            runID: runID, stage: stage, model: model, promptName: promptName, promptVersion: promptVersion,
            usage: usage, usdEstimate: usd, createdAt: now(), estimated: estimated)
        // An unstructured task does not inherit cancellation: a call that was paid for is billed even when the caller
        // was cancelled (GRDB refuses writes from a cancelled task).
        let store = store
        try await Task { try await store.recordLLMCall(record) }.value
        return usd
    }
}
