import Foundation

/// One event of a streamed Messages API call.
public enum LLMStreamEvent: Sendable {
    /// A piece of a `text` block.
    case textDelta(String)
    /// A `tool_use` block whose input JSON is complete.
    case toolUse(id: String, name: String, input: JSONValue)
    /// The finished message: all blocks (thinking blocks as `.opaque`), stop reason and usage. Always the last event.
    case completed(LLMResponse)
}

/// An `LLMClient` that can also stream. `LLMClient` itself stays unchanged; callers check with `as?`.
public protocol LLMStreamingClient: LLMClient {
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error>
}

/// A transport that hands out the response body line by line as it arrives (server-sent events).
/// Transports without it are read whole and split, which is what the test mocks do.
public protocol HTTPLineStreamingTransport: HTTPTransport {
    func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse)
}

extension URLSessionTransport: HTTPLineStreamingTransport {
    public func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    // `lines` drops blank lines; Anthropic sends every event's JSON on a single `data:` line.
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, http)
    }
}
