//
//  OpenRouterTypes.swift
//  Harness
//

import Foundation

// MARK: - Request

nonisolated struct ChatRequest: Encodable {
    var model: String
    var messages: [WireMessage]
    var tools: [WireTool]
    var stream: Bool = true
    var streamOptions = StreamOptions()
    /// Always sent so providers that size reasoning from the output limit see the same value on every request.
    var maxTokens = 32_000
    /// Restrict routing to zero-data-retention endpoints.
    var provider = ProviderPreferences()
    /// Omitted when nil so the provider uses its default reasoning behavior.
    var reasoning: Reasoning?

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, stream, provider, reasoning
        case streamOptions = "stream_options"
        case maxTokens = "max_tokens"
    }

    struct Reasoning: Encodable {
        var effort: String
    }

    struct StreamOptions: Encodable {
        var includeUsage = true
        enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
    }

    struct ProviderPreferences: Encodable {
        var zdr = true
    }
}

nonisolated struct WireMessage: Encodable {
    var role: String
    var content: String?
    var toolCalls: [WireToolCall]?
    var toolCallID: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        // Always send `content`, as an explicit null when absent; some providers require the key.
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
    }
}

nonisolated struct WireToolCall: Encodable {
    var id: String
    var type = "function"
    var function: Function

    struct Function: Encodable {
        var name: String
        var arguments: String
    }
}

nonisolated struct WireTool: Encodable {
    var type = "function"
    var function: Function

    struct Function: Encodable {
        var name: String
        var description: String
        var parameters: JSONValue
    }
}

// MARK: - Streaming response

nonisolated struct ChatChunk: Decodable {
    var choices: [Choice]?
    var usage: TokenUsage?
    var error: ErrorBody?
    /// The provider that served the request, for example "DeepInfra".
    var provider: String?

    struct Choice: Decodable {
        var delta: Delta?
        var finishReason: String?
        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable {
        var content: String?
        var toolCalls: [ToolCallDelta]?
        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCallDelta: Decodable {
        var index: Int?
        var id: String?
        var function: FunctionDelta?
    }

    struct FunctionDelta: Decodable {
        var name: String?
        var arguments: String?
    }

    struct ErrorBody: Decodable {
        var message: String?
    }
}

nonisolated struct TokenUsage: Codable, Hashable {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    var cost: Double?
    var completionTokensDetails: CompletionDetails?

    var reasoningTokens: Int? { completionTokensDetails?.reasoningTokens }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case cost
        case completionTokensDetails = "completion_tokens_details"
    }

    struct CompletionDetails: Codable, Hashable {
        var reasoningTokens: Int?
        enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" }
    }
}

/// A complete tool call requested by the model, as persisted and displayed.
nonisolated struct ToolCallRecord: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var arguments: String
}
