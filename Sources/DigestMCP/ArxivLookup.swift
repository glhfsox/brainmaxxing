import DigestCore
import Foundation

/// arXiv API queries the server needs beyond the pipeline's category feed: free-text search and lookup by id.
/// Every request waits on the shared 3 s `RateLimiter`; responses are parsed by `ArxivClient.parse`.
struct ArxivLookup: Sendable {
    let transport: HTTPTransport
    let rateLimiter: RateLimiter

    func search(query: String, categories: [String], since: Date?, max: Int) async throws -> [RawPaper] {
        guard let url = Self.searchURL(query: query, categories: categories, since: since, max: max) else {
            throw ToolError("query has no searchable words")
        }
        return try await get(url)
    }

    func paper(id: String) async throws -> RawPaper? {
        var c = URLComponents(string: ArxivClient.baseURL)
        c?.queryItems = [URLQueryItem(name: "id_list", value: id), URLQueryItem(name: "max_results", value: "1")]
        guard let url = c?.url else { throw ToolError("bad arXiv id \(id)") }
        return try await get(url).first { $0.id == id }
    }

    /// `all:` terms ANDed, optional `cat:` OR-group and `submittedDate` range, best relevance first.
    static func searchURL(query: String, categories: [String], since: Date?, max: Int) -> URL? {
        let words = query.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }).map(String.init)
        guard !words.isEmpty else { return nil }
        var parts = [words.map { "all:\($0)" }.joined(separator: " AND ")]
        let cats = categories.filter { $0.range(of: #"^[A-Za-z\-]+(\.[A-Za-z\-]+)?$"#, options: .regularExpression) != nil }
        if !cats.isEmpty { parts.append("(" + cats.map { "cat:\($0)" }.joined(separator: " OR ") + ")") }
        if let since {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMddHHmm"
            parts.append("submittedDate:[\(f.string(from: since)) TO 999912312359]")
        }
        var c = URLComponents(string: ArxivClient.baseURL)
        c?.queryItems = [
            URLQueryItem(name: "search_query", value: parts.joined(separator: " AND ")),
            URLQueryItem(name: "sortBy", value: "relevance"),
            URLQueryItem(name: "max_results", value: String(max)),
        ]
        return c?.url
    }

    private func get(_ url: URL) async throws -> [RawPaper] {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(ArxivClient.userAgent, forHTTPHeaderField: "User-Agent")
        try await rateLimiter.wait()
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw ToolError("arXiv is unreachable: \(error.localizedDescription)")
        }
        guard response.statusCode == 200 else { throw ToolError("arXiv API returned HTTP \(response.statusCode); try again later") }
        do {
            return try ArxivClient.parse(data)
        } catch {
            throw ToolError("arXiv returned a response that could not be parsed")
        }
    }
}
