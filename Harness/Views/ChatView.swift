//
//  ChatView.swift
//  Harness
//

import SwiftData
import SwiftUI

struct ChatView: View {
    let conversation: Conversation

    @Environment(\.modelContext) private var modelContext
    @Environment(SessionStore.self) private var sessionStore
    @State private var draft = ""
    @State private var showingTelemetry = false

    var body: some View {
        let session = sessionStore.session(for: conversation)
        let messages = conversation.sortedMessages
        let toolResults = Dictionary(
            messages.compactMap { message in message.toolCallID.map { ($0, message.content) } },
            uniquingKeysWith: { first, _ in first }
        )

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(messages.filter { $0.role != .tool }) { message in
                    MessageRow(message: message, toolResults: toolResults,
                               runningToolCallIDs: session.runningToolCallIDs, isTurnRunning: session.isRunning)
                }
                if session.isRunning {
                    StreamingRow(text: session.streamingText, toolCalls: session.streamingToolCalls)
                }
                if let error = session.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            inputBar(session: session)
        }
        .navigationTitle(conversation.title)
        .navigationSubtitle("\(conversation.modelOption.name) · \(conversation.reasoningEffort.title) · \(conversation.formattedCost)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                modelMenu
                    .disabled(session.isRunning)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Debug", systemImage: "ladybug") { showingTelemetry = true }
            }
        }
        .sheet(isPresented: $showingTelemetry) {
            TelemetryView(conversation: conversation)
        }
    }

    /// Model and reasoning effort for this conversation. Changes apply from the next message.
    private var modelMenu: some View {
        let current = conversation.modelOption
        let models = ModelCatalog.preset(for: current.id) == nil ? ModelCatalog.presets + [current] : ModelCatalog.presets
        let modelBinding = Binding(
            get: { conversation.resolvedModelID },
            set: { conversation.modelID = $0 }
        )
        let effortBinding = Binding(
            get: { conversation.reasoningEffort },
            set: { conversation.reasoningEffort = $0 }
        )

        return Menu {
            Picker("Model", selection: modelBinding) {
                ForEach(models) { option in
                    Text(option.name).tag(option.id)
                }
            }
            .pickerStyle(.menu)

            Picker("Reasoning Effort", selection: effortBinding) {
                ForEach(ReasoningEffort.allowed(for: current)) { effort in
                    Text(effort.title).tag(effort)
                }
            }
            .pickerStyle(.menu)
        } label: {
            Label("Model: \(current.name), reasoning \(conversation.reasoningEffort.title)", systemImage: "cpu")
        }
    }

    private func inputBar(session: ChatSession) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 20))
                .onSubmit { send(session) }

            if session.isRunning {
                Button("Stop", systemImage: "stop.circle.fill") { session.stop() }
                    .labelStyle(.iconOnly)
                    .font(.largeTitle)
                    .foregroundStyle(.red)
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill") { send(session) }
                    .labelStyle(.iconOnly)
                    .font(.largeTitle)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send(_ session: ChatSession) {
        if session.send(draft, in: modelContext) {
            draft = ""
        }
    }
}

private struct MessageRow: View {
    let message: Message
    let toolResults: [String: String]
    let runningToolCallIDs: Set<String>
    let isTurnRunning: Bool

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .foregroundStyle(.white)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 18))
            }
        case .assistant, .tool:
            VStack(alignment: .leading, spacing: 8) {
                if !message.content.isEmpty {
                    MarkdownText(source: message.content)
                }
                ForEach(message.toolCalls) { call in
                    ToolCallRow(call: call, result: toolResults[call.id], status: status(for: call))
                }
            }
        }
    }

    private func status(for call: ToolCallRecord) -> ToolCallRow.Status {
        if toolResults[call.id] != nil { return .done }
        if runningToolCallIDs.contains(call.id) { return .running }
        return isTurnRunning ? .pending : .done
    }
}

/// The assistant reply that is still streaming.
private struct StreamingRow: View {
    let text: String
    let toolCalls: [ToolCallRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if text.isEmpty && toolCalls.isEmpty {
                ProgressView()
            }
            if !text.isEmpty {
                MarkdownText(source: text)
            }
            ForEach(Array(toolCalls.enumerated()), id: \.offset) { _, call in
                ToolCallRow(call: call, result: nil, status: .streaming)
            }
        }
    }
}
