import Foundation
import Logging
import MCP

/// Wraps the stdio transport and counts JSON-RPC requests in and responses out, so the process can wait for answers to
/// requests that arrived just before stdin closed (the SDK handles each request in its own task and its loop
/// ends at EOF, which would otherwise exit `main` before those tasks reply).
actor DrainingTransport: Transport {
    private let inner: StdioTransport
    private var requests = 0
    private var responses = 0
    nonisolated let logger: Logger

    init(_ inner: StdioTransport) {
        self.inner = inner
        self.logger = inner.logger
    }

    func connect() async throws { try await inner.connect() }
    func disconnect() async { await inner.disconnect() }

    func send(_ data: Data) async throws {
        try await inner.send(data)
        responses += Self.count(data) { $0["id"] != nil && $0["method"] == nil }
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in await self.inner.receive() {
                        self.noteIncoming(data)
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Waits until every request received so far has been answered, or `timeout` passes.
    func drain(timeout: Duration = .seconds(30)) async {
        let deadline = ContinuousClock.now + timeout
        while responses < requests, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func noteIncoming(_ data: Data) {
        requests += Self.count(data) { $0["id"] != nil && $0["method"] != nil }
    }

    /// Messages in `data` (one object or a batch array) matching `predicate`.
    private static func count(_ data: Data, _ predicate: ([String: Any]) -> Bool) -> Int {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return 0 }
        let messages = (json as? [[String: Any]]) ?? [json as? [String: Any]].compactMap { $0 }
        return messages.filter(predicate).count
    }
}
