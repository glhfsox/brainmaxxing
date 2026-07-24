import Foundation

public struct LLMTextBlock: Sendable, Equatable {
    public var text: String
    public var cache: Bool
    public init(text: String, cache: Bool = false) {
        self.text = text
        self.cache = cache
    }
}

public struct ToolDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var strict: Bool
    public init(name: String, description: String, inputSchema: JSONValue, strict: Bool) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.strict = strict
    }
}

public enum ToolChoice: Sendable, Equatable { case auto, tool(String) }

public enum MessageContent: Sendable, Equatable {
    case text(String, cache: Bool)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, content: String, isError: Bool)
    /// A `thinking` / `redacted_thinking` block exactly as the API sent it. Only `AnthropicClient.stream` returns these;
    /// they must go back unchanged in the assistant turn that precedes a `tool_result`.
    case opaque(JSONValue)
}

public struct LLMMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public var role: Role
    public var content: [MessageContent]
    public init(role: Role, content: [MessageContent]) {
        self.role = role
        self.content = content
    }
}

public struct LLMRequest: Sendable {
    public var model: String
    public var system: [LLMTextBlock]
    public var messages: [LLMMessage]
    public var tools: [ToolDefinition]
    public var toolChoice: ToolChoice
    public var maxTokens: Int
    public var stage: Stage
    public var promptName: String?
    public var promptVersion: Int?
    /// Sent as `output_config: {"effort": ...}`; nil -> API default.
    public var effort: String?
    // Deliberately no temperature / top_p / top_k: the 5.5 models reject non-default values with 400.

    public init(
        model: String, system: [LLMTextBlock], messages: [LLMMessage], tools: [ToolDefinition] = [],
        toolChoice: ToolChoice = .auto, maxTokens: Int, stage: Stage, promptName: String? = nil, promptVersion: Int? = nil,
        effort: String? = nil
    ) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.maxTokens = maxTokens
        self.stage = stage
        self.promptName = promptName
        self.promptVersion = promptVersion
        self.effort = effort
    }
}

public struct LLMUsage: Sendable, Codable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public init(inputTokens: Int, outputTokens: Int, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}

public struct LLMResponse: Sendable {
    public let content: [MessageContent]
    public let stopReason: String
    public let usage: LLMUsage
    public let model: String

    public init(content: [MessageContent], stopReason: String, usage: LLMUsage, model: String) {
        self.content = content
        self.stopReason = stopReason
        self.usage = usage
        self.model = model
    }

    /// Decodes the input of the first `tool_use` block named `name`.
    public func toolInput<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        for block in content {
            if case let .toolUse(_, blockName, input) = block, blockName == name {
                do {
                    return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(input))
                } catch {
                    throw LLMError.invalidToolInput(name, error.localizedDescription)
                }
            }
        }
        throw LLMError.missingToolUse(name, stopReason: stopReason)
    }
}

public protocol LLMClient: Sendable {
    func complete(_ request: LLMRequest) async throws -> LLMResponse
}

public enum LLMError: LocalizedError, Equatable {
    case missingAPIKey
    /// Unattended run: the Keychain item needs a dialog this process may not show.
    case keychainInteractionRequired
    case budgetExceeded(spentUSD: Double, capUSD: Double)
    case unknownModelPricing(String)
    case promptTooLongForPricing(model: String, estimatedTokens: Int)
    case http(status: Int, type: String?, message: String)
    case transport(String)
    case invalidResponse(String)
    case missingToolUse(String, stopReason: String)
    case invalidToolInput(String, String)
    /// An `error` event inside a 200 streaming response (e.g. `overloaded_error`). Not retried: output was already billed.
    case streamError(type: String?, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "no API key: set ANTHROPIC_API_KEY or store the key in Keychain (service \(KeychainStore.anthropicService))"
        case .keychainInteractionRequired:
            "Keychain access to the Anthropic key needs your approval, which an unattended run cannot ask for: run "
                + "`digest-cli run --force` once in a terminal and choose \"Always Allow\", or export ANTHROPIC_API_KEY"
        case let .budgetExceeded(spent, cap):
            String(format: "daily LLM budget exhausted: $%.4f spent of $%.2f", spent, cap)
        case let .unknownModelPricing(model):
            "no pricing known for model \(model); refusing to call it"
        case let .promptTooLongForPricing(model, tokens):
            "prompt of ~\(tokens) tokens exceeds the flat-rate pricing tier of \(model)"
        case let .http(status, type, message):
            "Anthropic API error \(status)\(type.map { " (\($0))" } ?? ""): \(message)"
        case let .transport(message):
            "network error talking to the Anthropic API: \(message)"
        case let .invalidResponse(message):
            "unexpected Anthropic API response: \(message)"
        case let .missingToolUse(name, stopReason):
            "model did not call tool \(name) (stop_reason \(stopReason))"
        case let .invalidToolInput(name, reason):
            "tool \(name) input does not match the expected shape: \(reason)"
        case let .streamError(type, message):
            "Anthropic stream error\(type.map { " (\($0))" } ?? ""): \(message)"
        }
    }
}
