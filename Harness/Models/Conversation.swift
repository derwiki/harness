//
//  Conversation.swift
//  Harness
//

import Foundation
import SwiftData

@Model
final class Conversation {
    /// Stable identity. Unlike `persistentModelID`, it does not change when the object is first saved.
    var uuid: UUID = UUID()
    var title: String = "New Chat"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var nextMessageOrder: Int = 0
    /// OpenRouter model slug. Empty means the default model ID from Settings.
    var modelID: String = ""
    var reasoningEffortRaw: String = ReasoningEffort.default.rawValue

    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var messages: [Message] = []

    @Relationship(deleteRule: .cascade, inverse: \TurnRecord.conversation)
    var turns: [TurnRecord] = []

    init(modelID: String = "") {
        self.modelID = modelID
    }

    var sortedMessages: [Message] {
        messages.sorted { $0.order < $1.order }
    }

    var totalCost: Double {
        turns.reduce(0) { $0 + $1.totalCost }
    }

    var formattedCost: String {
        Self.formatCost(totalCost)
    }

    /// Cost as "$1.12". Costs above zero but under a cent show as "<$0.01".
    static func formatCost(_ cost: Double) -> String {
        if cost > 0 && cost < 0.01 { return "<$0.01" }
        return cost.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    /// The slug to send, after falling back to Settings.
    var resolvedModelID: String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AppSettings.modelID : trimmed
    }

    var modelOption: ModelOption {
        ModelCatalog.option(for: resolvedModelID)
    }

    /// The effort to use. Falls back to Default if the stored value is not valid for the current model.
    var reasoningEffort: ReasoningEffort {
        get {
            let effort = ReasoningEffort(rawValue: reasoningEffortRaw) ?? .default
            return ReasoningEffort.allowed(for: modelOption).contains(effort) ? effort : .default
        }
        set { reasoningEffortRaw = newValue.rawValue }
    }
}
