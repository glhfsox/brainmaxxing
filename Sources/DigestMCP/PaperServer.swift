import DigestCore
import Foundation
import MCP

/// Builds the MCP server with tools and resources registered; the caller picks the transport.
enum PaperServer {
    static let name = "brainmaxxing"
    static let version = "0.1.0"

    static func make(context: ServerContext) async -> Server {
        let tools = PaperTools(context: context)
        let server = Server(
            name: name, version: version,
            instructions: "Paper lookup for the brainmaxxing digest: arXiv search, stored papers and full texts, past digests and chat.",
            capabilities: .init(resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: ToolCatalog.tools) }
        await server.withMethodHandler(CallTool.self) { params in await tools.call(params.name, params.arguments) }
        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: [Resource(name: "Today's digest", uri: "digest://today",
                                       description: "The digest dated today, as JSON.", mimeType: "application/json")])
        }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            .init(templates: [
                Resource.Template(uriTemplate: "digest://{date}", name: "Digest by date",
                                  description: "The stored digest of a day (YYYY-MM-DD), as JSON.", mimeType: "application/json"),
                Resource.Template(uriTemplate: "paper://{id}", name: "Paper",
                                  description: "Paper metadata and abstract (arXiv id or stored OpenAlex W... id), as Markdown.", mimeType: "text/markdown"),
            ])
        }
        await server.withMethodHandler(ReadResource.self) { params in
            do {
                return try await tools.readResource(params.uri)
            } catch let error as MCPError {
                throw error
            } catch {
                throw MCPError.invalidParams(PaperTools.short(error))
            }
        }
        return server
    }
}
