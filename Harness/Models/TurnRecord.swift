//
//  TurnRecord.swift
//  Harness
//

import Foundation
import SwiftData

/// Metrics for one model request inside a turn.
nonisolated struct RequestMetric: Codable, Hashable {
    var iteration: Int
    var timeToFirstByteMs: Double?
    var timeToFirstTokenMs: Double?
    var latencyMs: Double
    var usage: TokenUsage?
    var finishReason: String?
    var toolCallCount: Int
    var malformedChunks: Int
    /// The provider that served the request. Optional so records saved before this field still decode.
    var provider: String?
}

/// A tool call whose arguments could not be parsed.
nonisolated struct ToolParseFailure: Codable, Hashable {
    var toolName: String
    var toolCallID: String
    var rawArguments: String
    var error: String
}

/// Telemetry for one user turn: everything from sending a message to the final answer.
@Model
final class TurnRecord {
    var startedAt: Date = Date()
    var model: String = ""
    var reasoningEffort: String = ReasoningEffort.default.rawValue
    var latencyMs: Double = 0
    /// One of: running, completed, max_iterations, cancelled, error.
    var stopReason: String = "running"
    var errorMessage: String?
    var requestsData: Data?
    var parseFailuresData: Data?
    var conversation: Conversation?

    init(model: String, reasoningEffort: ReasoningEffort) {
        self.model = model
        self.reasoningEffort = reasoningEffort.rawValue
    }

    var requests: [RequestMetric] {
        get { Self.decode(requestsData) }
        set { requestsData = try? JSONEncoder().encode(newValue) }
    }

    var parseFailures: [ToolParseFailure] {
        get { Self.decode(parseFailuresData) }
        set { parseFailuresData = try? JSONEncoder().encode(newValue) }
    }

    var totalTokens: Int {
        requests.reduce(0) { $0 + ($1.usage?.totalTokens ?? 0) }
    }

    /// USD cost reported by OpenRouter. Requests cancelled before their final usage chunk add nothing.
    var totalCost: Double {
        requests.reduce(0) { $0 + ($1.usage?.cost ?? 0) }
    }

    private static func decode<T: Decodable>(_ data: Data?) -> [T] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }
}
