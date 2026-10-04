//
//  MarkdownText.swift
//  Harness
//

import SwiftUI

/// Renders common Markdown: headings, list items, fenced code blocks, and inline styles.
struct MarkdownText: View {
    let source: String
    /// While streaming, the last block is still growing. It renders as plain text so that
    /// half-received markers such as "**bol" do not switch style and reflow on every token.
    var isStreaming = false

    var body: some View {
        let blocks = MarkdownBlock.parse(source)
        VStack(alignment: .leading, spacing: 8) {
            // Blocks have no stable identity and are re-parsed while streaming, so position is the identity.
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, plain: isStreaming && index == blocks.count - 1)
            }
        }
        // SF Mono: equal-width characters keep streamed text from shifting within a line.
        .fontDesign(.monospaced)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock, plain: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text, plain: plain)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
        case .listItem(let marker, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: marker)
                inline(text, plain: plain)
            }
            .padding(.leading, CGFloat(indent) * 12)
        case .code(let code):
            ScrollView(.horizontal) {
                Text(verbatim: code)
                    .font(.callout.monospaced())
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
        case .paragraph(let text):
            inline(text, plain: plain)
        }
    }

    private func inline(_ text: String, plain: Bool) -> Text {
        if plain { return Text(verbatim: text) }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(verbatim: text)
    }
}

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case listItem(marker: String, text: String, indent: Int)
    case code(String)
    case paragraph(String)

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if let heading = headingLevel(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading, text: String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if let item = listItem(line) {
                flushParagraph()
                blocks.append(item)
                continue
            }
            paragraph.append(line)
        }

        flushParagraph()
        // An unclosed fence (common while streaming) still renders as code.
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix(while: { $0 == " " }).count / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
            return .listItem(marker: "•", text: String(trimmed.dropFirst(2)), indent: indent)
        }
        let digits = trimmed.prefix(while: \.isNumber)
        if !digits.isEmpty, trimmed.dropFirst(digits.count).hasPrefix(". ") {
            return .listItem(marker: "\(digits).", text: String(trimmed.dropFirst(digits.count + 2)), indent: indent)
        }
        return nil
    }
}
