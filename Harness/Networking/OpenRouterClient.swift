//
//  OpenRouterClient.swift
//  Harness
//

import Foundation

enum OpenRouterError: LocalizedError {
    case http(status: Int, message: String)
    case stream(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .http(let status, let message): "OpenRouter returned HTTP \(status): \(message)"
        case .stream(let message): "OpenRouter stream error: \(message)"
        case .invalidResponse: "OpenRouter returned an invalid response."
        }
    }
}

/// The accumulated outcome of one streamed chat completion.
struct StreamResult {
    var content = ""
    var toolCalls: [ToolCallRecord] = []
    var usage: TokenUsage?
    var finishReason: String?
    var timeToFirstByte: Duration?
    var timeToFirstToken: Duration?
    var totalDuration: Duration = .zero
    var malformedChunks = 0
}

struct OpenRouterClient {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    /// Streams a chat completion over SSE.
    /// `onUpdate` receives the accumulated text and tool calls after each chunk.
    func stream(
        _ chatRequest: ChatRequest,
        apiKey: String,
        onUpdate: (_ content: String, _ toolCalls: [ToolCallRecord]) -> Void
    ) async throws -> StreamResult {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Harness", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONEncoder().encode(chatRequest)

        let clock = ContinuousClock()
        let start = clock.now
        var result = StreamResult()

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        result.timeToFirstByte = clock.now - start
        guard let http = response as? HTTPURLResponse else { throw OpenRouterError.invalidResponse }

        guard http.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 4_000 { break }
            }
            throw OpenRouterError.http(status: http.statusCode, message: Self.errorMessage(fromBody: body))
        }

        // Tool calls arrive as fragments keyed by index; accumulate them in order.
        var partialCalls: [Int: ToolCallRecord] = [:]
        let decoder = JSONDecoder()

        func sortedCalls() -> [ToolCallRecord] {
            partialCalls.sorted { $0.key < $1.key }.map(\.value)
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            // Lines starting with ":" are SSE comments (OpenRouter keep-alives); skip them and non-data fields.
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }

            guard let chunk = try? decoder.decode(ChatChunk.self, from: Data(payload.utf8)) else {
                result.malformedChunks += 1
                continue
            }
            if let error = chunk.error {
                throw OpenRouterError.stream(error.message ?? "Unknown error")
            }
            if let usage = chunk.usage {
                result.usage = usage
            }

            var changed = false
            for choice in chunk.choices ?? [] {
                if let reason = choice.finishReason { result.finishReason = reason }
                guard let delta = choice.delta else { continue }

                if let text = delta.content, !text.isEmpty {
                    if result.timeToFirstToken == nil { result.timeToFirstToken = clock.now - start }
                    result.content += text
                    changed = true
                }

                for (position, fragment) in (delta.toolCalls ?? []).enumerated() {
                    if result.timeToFirstToken == nil { result.timeToFirstToken = clock.now - start }
                    let index = fragment.index ?? position
                    var call = partialCalls[index] ?? ToolCallRecord(id: "", name: "", arguments: "")
                    if let id = fragment.id, !id.isEmpty, call.id.isEmpty { call.id = id }
                    if let name = fragment.function?.name, !name.isEmpty, call.name.isEmpty { call.name = name }
                    if let arguments = fragment.function?.arguments { call.arguments += arguments }
                    partialCalls[index] = call
                    changed = true
                }
            }
            if changed { onUpdate(result.content, sortedCalls()) }
        }

        result.toolCalls = sortedCalls().map { call in
            var call = call
            if call.id.isEmpty { call.id = "call_\(UUID().uuidString)" }
            if call.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { call.arguments = "{}" }
            return call
        }
        result.totalDuration = clock.now - start
        return result
    }

    /// Pulls `error.message` out of an OpenRouter JSON error body, falling back to the raw text.
    private static func errorMessage(fromBody body: String) -> String {
        struct Envelope: Decodable {
            struct Inner: Decodable { var message: String? }
            var error: Inner?
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(body.utf8)),
           let message = envelope.error?.message {
            return message
        }
        return body.isEmpty ? "No response body." : String(body.prefix(500))
    }
}

extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}
