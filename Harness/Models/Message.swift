//
//  Message.swift
//  Harness
//

import Foundation
import SwiftData

enum MessageRole: String, Codable {
    case user
    case assistant
    case tool
}

@Model
final class Message {
    var order: Int = 0
    var roleRaw: String = MessageRole.user.rawValue
    var content: String = ""
    var createdAt: Date = Date()
    /// JSON-encoded `[ToolCallRecord]` requested by an assistant message.
    var toolCallsData: Data?
    /// For tool-result messages: the id of the tool call this message answers.
    var toolCallID: String?
    var toolName: String?
    var conversation: Conversation?

    init(order: Int, role: MessageRole, content: String, toolCalls: [ToolCallRecord] = [],
         toolCallID: String? = nil, toolName: String? = nil) {
        self.order = order
        self.roleRaw = role.rawValue
        self.content = content
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.toolCalls = toolCalls
    }

    var role: MessageRole {
        MessageRole(rawValue: roleRaw) ?? .assistant
    }

    var toolCalls: [ToolCallRecord] {
        get {
            guard let toolCallsData else { return [] }
            return (try? JSONDecoder().decode([ToolCallRecord].self, from: toolCallsData)) ?? []
        }
        set {
            toolCallsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
    }
}
