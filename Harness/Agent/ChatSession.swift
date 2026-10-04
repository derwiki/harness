//
//  ChatSession.swift
//  Harness
//

import Foundation
import Observation
import SwiftData

/// Runs the agent loop for one conversation and exposes in-flight streaming state to the UI.
@Observable
final class ChatSession {
    static let maxIterations = 10

    let conversation: Conversation
    private(set) var isRunning = false
    private(set) var streamingText = ""
    private(set) var streamingToolCalls: [ToolCallRecord] = []
    private(set) var runningToolCallIDs: Set<String> = []
    var errorMessage: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var parseFailures: [ToolParseFailure] = []
    @ObservationIgnored private let client = OpenRouterClient()

    init(conversation: Conversation) {
        self.conversation = conversation
    }

    /// Starts a turn. Returns false (and sets `errorMessage`) when the turn cannot start.
    @discardableResult
    func send(_ text: String, in context: ModelContext) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return false }
        guard let apiKey = KeychainStore.readAPIKey(), !apiKey.isEmpty else {
            errorMessage = "Add your OpenRouter API key in Settings."
            return false
        }
        let model = conversation.resolvedModelID
        guard !model.isEmpty else {
            errorMessage = "Pick a model, or set a default model ID in Settings."
            return false
        }
        let effort = conversation.reasoningEffort

        errorMessage = nil
        if conversation.messages.isEmpty {
            conversation.title = String(trimmed.prefix(48))
        }
        append(.user, content: trimmed, in: context)
        try? context.save()

        isRunning = true
        task = Task {
            await runTurn(apiKey: apiKey, model: model, effort: effort, context: context)
            isRunning = false
            task = nil
        }
        return true
    }

    func stop() {
        task?.cancel()
    }

    // MARK: - Agent loop

    private func runTurn(apiKey: String, model: String, effort: ReasoningEffort, context: ModelContext) async {
        let turn = TurnRecord(model: model, reasoningEffort: effort)
        context.insert(turn)
        turn.conversation = conversation
        parseFailures = []
        var metrics: [RequestMetric] = []
        let clock = ContinuousClock()
        let turnStart = clock.now

        do {
            for iteration in 1...Self.maxIterations {
                try Task.checkCancellation()
                streamingText = ""
                streamingToolCalls = []

                let request = ChatRequest(
                    model: model,
                    messages: wireMessages(),
                    tools: ToolRegistry.wireDefinitions,
                    reasoning: effort.wireValue.map { ChatRequest.Reasoning(effort: $0) }
                )
                let result = try await client.stream(request, apiKey: apiKey) { content, toolCalls in
                    streamingText = content
                    streamingToolCalls = toolCalls
                }

                metrics.append(RequestMetric(
                    iteration: iteration,
                    timeToFirstByteMs: result.timeToFirstByte?.milliseconds,
                    timeToFirstTokenMs: result.timeToFirstToken?.milliseconds,
                    latencyMs: result.totalDuration.milliseconds,
                    usage: result.usage,
                    finishReason: result.finishReason,
                    toolCallCount: result.toolCalls.count,
                    malformedChunks: result.malformedChunks
                ))
                // Store as we go so the running cost in the chat header updates after each request.
                turn.requests = metrics

                append(.assistant, content: result.content, toolCalls: result.toolCalls, in: context)
                streamingText = ""
                streamingToolCalls = []

                if result.toolCalls.isEmpty {
                    turn.stopReason = "completed"
                    break
                }
                if iteration == Self.maxIterations {
                    // Keep the history valid: every tool call needs a matching result.
                    closeDanglingToolCalls(reason: "Not run: the agent reached its limit of \(Self.maxIterations) iterations.", in: context)
                    turn.stopReason = "max_iterations"
                    errorMessage = "Stopped after \(Self.maxIterations) iterations."
                    break
                }

                for call in result.toolCalls {
                    try Task.checkCancellation()
                    let output = await execute(call)
                    append(.tool, content: output, toolCallID: call.id, toolName: call.name, in: context)
                }
            }
        } catch {
            // The conversation was deleted while this turn ran; there is nothing left to update.
            guard !conversation.isDeleted, conversation.modelContext != nil else { return }
            if Self.isCancellation(error) {
                turn.stopReason = "cancelled"
            } else {
                turn.stopReason = "error"
                turn.errorMessage = error.localizedDescription
                errorMessage = error.localizedDescription
            }
            // Keep any partial answer, then answer tool calls that never ran.
            if !streamingText.isEmpty {
                append(.assistant, content: streamingText, in: context)
            }
            closeDanglingToolCalls(reason: "Not run: the turn was stopped before this tool finished.", in: context)
        }

        streamingText = ""
        streamingToolCalls = []
        turn.requests = metrics
        turn.parseFailures = parseFailures
        turn.latencyMs = (clock.now - turnStart).milliseconds
        try? context.save()
    }

    private func execute(_ call: ToolCallRecord) async -> String {
        guard JSONValue.isJSONObject(call.arguments) else {
            parseFailures.append(ToolParseFailure(
                toolName: call.name, toolCallID: call.id,
                rawArguments: String(call.arguments.prefix(2_000)),
                error: "Arguments are not a valid JSON object."
            ))
            return "Error: the arguments were not a valid JSON object. Call the tool again with valid JSON."
        }
        guard let tool = ToolRegistry.tool(named: call.name) else {
            return "Error: there is no tool named '\(call.name)'."
        }

        runningToolCallIDs.insert(call.id)
        defer { runningToolCallIDs.remove(call.id) }
        do {
            return try await tool.run(argumentsJSON: call.arguments)
        } catch let error as ToolArgumentError {
            parseFailures.append(ToolParseFailure(
                toolName: call.name, toolCallID: call.id,
                rawArguments: String(call.arguments.prefix(2_000)),
                error: error.message
            ))
            return "Error: \(error.message)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - History

    private func wireMessages() -> [WireMessage] {
        var result = [WireMessage(role: "system", content: Self.systemPrompt())]
        for message in conversation.sortedMessages {
            switch message.role {
            case .user:
                result.append(WireMessage(role: "user", content: message.content))
            case .assistant:
                let calls = message.toolCalls
                if calls.isEmpty && message.content.isEmpty { continue }
                result.append(WireMessage(
                    role: "assistant",
                    content: message.content.isEmpty ? nil : message.content,
                    toolCalls: calls.isEmpty ? nil : calls.map { call in
                        // Providers reject malformed argument JSON in history, so send an empty object instead.
                        let arguments = JSONValue.isJSONObject(call.arguments) ? call.arguments : "{}"
                        return WireToolCall(id: call.id, function: .init(name: call.name, arguments: arguments))
                    }
                ))
            case .tool:
                result.append(WireMessage(role: "tool", content: message.content, toolCallID: message.toolCallID))
            }
        }
        return result
    }

    private func closeDanglingToolCalls(reason: String, in context: ModelContext) {
        guard let lastAssistant = conversation.sortedMessages.last(where: { $0.role == .assistant }) else { return }
        let answered = Set(conversation.messages.compactMap { $0.role == .tool ? $0.toolCallID : nil })
        for call in lastAssistant.toolCalls where !answered.contains(call.id) {
            append(.tool, content: reason, toolCallID: call.id, toolName: call.name, in: context)
        }
    }

    private func append(_ role: MessageRole, content: String, toolCalls: [ToolCallRecord] = [],
                        toolCallID: String? = nil, toolName: String? = nil, in context: ModelContext) {
        let message = Message(order: conversation.nextMessageOrder, role: role, content: content,
                              toolCalls: toolCalls, toolCallID: toolCallID, toolName: toolName)
        conversation.nextMessageOrder += 1
        context.insert(message)
        message.conversation = conversation
        conversation.updatedAt = Date()
    }

    private static func systemPrompt() -> String {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let weekday = now.formatted(.dateTime.weekday(.wide))
        return """
            You are Harness, a helpful assistant in an iOS app.
            The current local date and time is \(formatter.string(from: now)) (\(weekday)). \
            The user's time zone is \(TimeZone.current.identifier).
            Use the available tools when they help you answer. Format answers with Markdown and keep them concise.
            """
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
    }
}

/// Keeps one `ChatSession` per conversation so a running turn survives navigation.
@Observable
final class SessionStore {
    @ObservationIgnored private var sessions: [UUID: ChatSession] = [:]

    func session(for conversation: Conversation) -> ChatSession {
        if let existing = sessions[conversation.uuid] { return existing }
        let session = ChatSession(conversation: conversation)
        sessions[conversation.uuid] = session
        return session
    }

    func discard(_ conversation: Conversation) {
        sessions.removeValue(forKey: conversation.uuid)?.stop()
    }
}
