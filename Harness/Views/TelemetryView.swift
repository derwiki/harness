//
//  TelemetryView.swift
//  Harness
//

import SwiftUI

/// Debug sheet: per-turn latency, token usage, and tool-call parse failures.
struct TelemetryView: View {
    let conversation: Conversation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let turns = conversation.turns.sorted { $0.startedAt > $1.startedAt }

        NavigationStack {
            List {
                if turns.isEmpty {
                    ContentUnavailableView("No Turns Yet", systemImage: "chart.bar",
                                           description: Text("Send a message to record telemetry."))
                }
                ForEach(turns) { turn in
                    TurnSection(turn: turn)
                }
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct TurnSection: View {
    let turn: TurnRecord

    var body: some View {
        let requests = turn.requests
        let failures = turn.parseFailures

        Section {
            LabeledContent("Model", value: turn.model)
            LabeledContent("Reasoning effort", value: ReasoningEffort(rawValue: turn.reasoningEffort)?.title ?? turn.reasoningEffort)
            LabeledContent("Stop reason", value: turn.stopReason)
            LabeledContent("Total latency", value: Self.ms(turn.latencyMs))
            LabeledContent("Requests", value: "\(requests.count)")
            LabeledContent("Total tokens", value: "\(turn.totalTokens)")
            LabeledContent("Parse failures", value: "\(failures.count)")
            if let error = turn.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            ForEach(requests, id: \.iteration) { request in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Request \(request.iteration)").font(.subheadline.weight(.semibold))
                    Group {
                        Text("Latency \(Self.ms(request.latencyMs)) · first byte \(Self.ms(request.timeToFirstByteMs)) · first token \(Self.ms(request.timeToFirstTokenMs))")
                        Text("Tokens: prompt \(Self.count(request.usage?.promptTokens)) · completion \(Self.count(request.usage?.completionTokens)) · reasoning \(Self.count(request.usage?.reasoningTokens)) · total \(Self.count(request.usage?.totalTokens))")
                        if let cost = request.usage?.cost {
                            Text("Cost: \(cost, format: .currency(code: "USD").precision(.fractionLength(2...6)))")
                        }
                        Text("Finish: \(request.finishReason ?? "–") · tool calls \(request.toolCallCount) · malformed chunks \(request.malformedChunks)")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            ForEach(failures, id: \.self) { failure in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Parse failure: \(failure.toolName)").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                    Text(failure.error).font(.caption)
                    Text(verbatim: failure.rawArguments).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(turn.startedAt, format: .dateTime.month().day().hour().minute().second())
        }
    }

    private static func ms(_ value: Double?) -> String {
        guard let value else { return "–" }
        return "\(Int(value.rounded())) ms"
    }

    private static func count(_ value: Int?) -> String {
        value.map(String.init) ?? "–"
    }
}
