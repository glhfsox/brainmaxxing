import DigestCore
import Foundation

/// Everything the tools need. The store opens on first use, so startup touches neither disk nor network.
struct ServerContext: Sendable {
    let paths: AppPaths
    let store: LazyStore
    let arxiv: ArxivLookup
    let fullText: FullTextFetcher
    /// Anonymous OpenAlex: its own 0.2 s limiter, never arXiv's; no `mailto`, no key.
    let openalex: OpenAlexClient
    let now: @Sendable () -> Date

    /// Production wiring: one arXiv `RateLimiter` (1 request / 3 s) shared by search, metadata and full text.
    static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> ServerContext {
        let paths = AppPaths.resolve(environment: environment)
        let transport = URLSessionTransport()
        let limiter = RateLimiter(minInterval: 3)
        return ServerContext(
            paths: paths, store: LazyStore(url: paths.database),
            arxiv: ArxivLookup(transport: transport, rateLimiter: limiter),
            fullText: ArxivFullTextFetcher(transport: transport, rateLimiter: limiter),
            openalex: OpenAlexClient(transport: transport), now: { Date() })
    }
}

/// Opens `digest.sqlite` on the first tool call that needs it and keeps it open.
actor LazyStore {
    private let url: URL
    private var store: Store?

    init(url: URL) { self.url = url }

    func get() throws -> Store {
        if let store { return store }
        let opened = try Store(url: url)
        store = opened
        return opened
    }
}

/// Errors a tool reports back to the model as `isError` results (never thrown out of the server).
struct ToolError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum PaperID {
    /// `arXiv:2610.12345v2`, `https://arxiv.org/abs/2610.12345`, `2610.12345v1` -> `2610.12345`; old-style ids keep their `/`.
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://arxiv.org/abs/", "http://arxiv.org/abs/", "https://arxiv.org/pdf/", "arxiv.org/abs/", "arXiv:", "arxiv:"]
        where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if s.hasSuffix(".pdf") { s = String(s.dropLast(4)) }
        if let v = s.lastIndex(of: "v"), v != s.startIndex, Int(s[s.index(after: v)...]) != nil,
           s[s.index(before: v)].isNumber {
            s = String(s[..<v])
        }
        return s
    }

    static func isValid(_ id: String) -> Bool {
        id.range(of: #"^(\d{4}\.\d{4,5}|[a-z\-]+(\.[A-Z]{2})?/\d{7})$"#, options: .regularExpression) != nil
    }

    /// `W123`, `w123`, `https://openalex.org/W123` -> `W123`; nil for anything else.
    static func openalex(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        guard short.range(of: #"^[Ww]\d+$"#, options: .regularExpression) != nil else { return nil }
        return "W" + short.dropFirst()
    }

    /// An arXiv id (normalized) or a short OpenAlex id; nil when it is neither.
    static func resolve(_ raw: String) -> String? {
        if let w = openalex(raw) { return w }
        let id = normalize(raw)
        return isValid(id) ? id : nil
    }

    static func isOpenAlex(_ id: String) -> Bool { id.hasPrefix("W") }
}
