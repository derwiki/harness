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
    @State private var dictation = DictationController()

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
                    StreamingRow(text: session.pacer.displayedText, toolCalls: session.streamingToolCalls)
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
        VStack(alignment: .leading, spacing: 6) {
            if let error = dictation.errorMessage {
                Label(error, systemImage: "mic.slash")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if case .recording(let startedAt) = dictation.state {
                    recordingPill(startedAt: startedAt)
                } else {
                    TextField("Message", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 20))
                        .onSubmit { send(session) }
                }
                dictationButton(session: session)
                sendOrStopButton(session: session)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .onDisappear { dictation.cancel() }
    }

    private func recordingPill(startedAt: Date) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
            Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                .monospacedDigit()
            LevelMeter(levels: dictation.levels)
            Spacer()
            Button("Cancel", systemImage: "xmark.circle.fill") { dictation.cancel() }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private func dictationButton(session: ChatSession) -> some View {
        switch dictation.state {
        case .idle:
            Button("Dictate", systemImage: "mic.circle.fill") {
                Task { await dictation.start() }
            }
            .labelStyle(.iconOnly)
            .font(.largeTitle)
            .foregroundStyle(.secondary)
        case .recording:
            Button("Finish Dictation", systemImage: "checkmark.circle.fill") {
                Task {
                    guard let text = await dictation.stopAndTranscribe() else { return }
                    // Send right away, together with anything already typed. If a turn is still
                    // running and the message cannot be sent, the text stays in the draft.
                    draft = draft.isEmpty ? text : draft + " " + text
                    send(session)
                }
            }
            .labelStyle(.iconOnly)
            .font(.largeTitle)
            .foregroundStyle(.red)
        case .transcribing:
            ProgressView()
                .frame(width: 37, height: 37)
                .accessibilityLabel("Transcribing")
        }
    }

    @ViewBuilder
    private func sendOrStopButton(session: ChatSession) -> some View {
        if session.isRunning {
            Button("Stop", systemImage: "stop.circle.fill") { session.stop() }
                .labelStyle(.iconOnly)
                .font(.largeTitle)
                .foregroundStyle(.red)
        } else {
            Button("Send", systemImage: "arrow.up.circle.fill") { send(session) }
                .labelStyle(.iconOnly)
                .font(.largeTitle)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || dictation.state != .idle)
        }
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

/// Live microphone level: one bar per recent sample, newest on the right.
private struct LevelMeter: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(.red)
                    .frame(width: 3, height: 3 + CGFloat(levels[index]) * 19)
            }
        }
        .frame(height: 22)
        .animation(.linear(duration: 0.05), value: levels)
        .accessibilityLabel("Microphone level")
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

#Preview("Level meter") {
    // A rising and falling voice, quiet at the edges.
    let levels: [Float] = (0..<DictationController.levelHistoryCount).map { index in
        let x = Float(index) / Float(DictationController.levelHistoryCount - 1)
        return max(0, sin(x * .pi) * (0.55 + 0.45 * sin(x * 19)))
    }
    HStack(spacing: 8) {
        Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.red)
        Text(verbatim: "0:07").monospacedDigit()
        LevelMeter(levels: levels)
        Spacer()
        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
    .padding()
}
