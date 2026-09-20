import DigestCore
import Foundation
import MCP

/// `DigestMCP`: MCP server over stdio. stdout carries the protocol only; diagnostics go to stderr / os_log.
@main
struct DigestMCPMain {
    static func main() async {
        let context = ServerContext.live()
        let server = await PaperServer.make(context: context)
        let transport = DrainingTransport(StdioTransport())
        do {
            try await server.start(transport: transport)
        } catch {
            FileHandle.standardError.write(Data("DigestMCP: cannot start stdio transport: \(error)\n".utf8))
            exit(1)
        }
        await server.waitUntilCompleted()
        // stdin closed: answer what already arrived before exiting.
        await transport.drain()
    }
}
