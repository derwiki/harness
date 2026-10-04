//
//  ToolCallRow.swift
//  Harness
//

import SwiftUI

/// A collapsible row that shows one tool call's arguments and result.
struct ToolCallRow: View {
    enum Status {
        case streaming, running, done, pending
    }

    let call: ToolCallRecord
    let result: String?
    let status: Status

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                section("Arguments", text: JSONValue.prettyPrinted(call.arguments))
                if let result {
                    section("Result", text: result)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.secondary)
                Text(verbatim: call.name.isEmpty ? "tool" : call.name)
                    .font(.callout.monospaced())
                Spacer()
                statusView
            }
        }
        .padding(10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .streaming, .running:
            ProgressView().controlSize(.small)
        case .done:
            let failed = result?.hasPrefix("Error:") == true || result?.hasPrefix("Not run:") == true
            Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(failed ? .orange : .green)
                .accessibilityLabel(failed ? "Failed" : "Done")
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Pending")
        }
    }

    private func section(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(verbatim: text.isEmpty ? "(empty)" : text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
