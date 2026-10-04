//
//  WebFetchTool.swift
//  Harness
//

import Foundation

struct WebFetchTool: Tool {
    static let maxCharacters = 20_000

    let name = "web_fetch"
    let description = """
        Fetches a web page with an HTTP GET request and returns its readable text with HTML removed. \
        Output is truncated to 20,000 characters.
        """

    var parameters: JSONValue {
        [
            "type": "object",
            "properties": [
                "url": ["type": "string", "description": "The absolute http or https URL to fetch."],
            ],
            "required": ["url"],
            "additionalProperties": false,
        ]
    }

    private struct Arguments: Decodable {
        let url: String
    }

    func run(argumentsJSON: String) async throws -> String {
        let arguments = try decodeToolArguments(Arguments.self, from: argumentsJSON)
        guard let url = URL(string: arguments.url.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host() != nil
        else {
            throw ToolArgumentError(message: "'url' must be an absolute http or https URL.")
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS like Mac OS X) Harness/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let mimeType = response.mimeType?.lowercased() ?? ""

        let binaryPrefixes = ["image/", "audio/", "video/", "font/", "application/pdf", "application/octet-stream", "application/zip"]
        if binaryPrefixes.contains(where: mimeType.hasPrefix) {
            return "URL: \(response.url?.absoluteString ?? url.absoluteString)\nStatus: \(status)\nUnsupported content type: \(mimeType)"
        }

        let raw = Self.decodeText(data, encodingName: response.textEncodingName)
        let looksLikeHTML = mimeType.contains("html") || (mimeType.isEmpty && raw.prefix(1_000).lowercased().contains("<html"))
        let text = looksLikeHTML ? await HTMLStripper.strip(raw) : raw

        var body = String(text.prefix(Self.maxCharacters))
        if text.count > Self.maxCharacters {
            body += "\n\n[Truncated: showing \(Self.maxCharacters) of \(text.count) characters.]"
        }
        return """
            URL: \(response.url?.absoluteString ?? url.absoluteString)
            Status: \(status)
            Content-Type: \(mimeType.isEmpty ? "unknown" : mimeType)

            \(body)
            """
    }

    private static func decodeText(_ data: Data, encodingName: String?) -> String {
        if let encodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

/// Converts HTML to readable plain text. Runs off the main actor because pages can be large.
nonisolated enum HTMLStripper {
    @concurrent
    static func strip(_ html: String) async -> String {
        stripSynchronously(html)
    }

    static func stripSynchronously(_ html: String) -> String {
        var text = html
        let title = firstMatch(in: text, pattern: #"<title[^>]*>(.*?)</title>"#)

        text = replace(text, #"<!--.*?-->"#, with: " ")
        text = replace(text, #"<(script|style|noscript|svg|template|iframe|head)\b[^>]*>.*?</\1\s*>"#, with: " ")
        text = replace(text, #"<br\s*/?>"#, with: "\n")
        text = replace(
            text,
            #"</?(p|div|section|article|header|footer|nav|aside|main|li|ul|ol|tr|table|h[1-6]|blockquote|pre|dl|dt|dd|form|figure|figcaption)\b[^>]*>"#,
            with: "\n"
        )
        text = replace(text, #"<[^>]+>"#, with: "")
        text = decodeEntities(text)
        text = replace(text, #"[ \t\r\f\x{00A0}]+"#, with: " ")
        text = replace(text, #" *\n *"#, with: "\n")
        text = replace(text, #"\n{3,}"#, with: "\n\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let title {
            let cleanTitle = decodeEntities(title).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanTitle.isEmpty { text = "Title: \(cleanTitle)\n\n" + text }
        }
        return text
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static func replace(_ text: String, _ pattern: String, with template: String) -> String {
        guard let regex = regex(pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: NSRegularExpression.escapedTemplate(for: template)
        )
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = regex(pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®", "trade": "™", "middot": "·",
    ]

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        output.reserveCapacity(text.utf8.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "&",
               let semicolon = text[index...].prefix(12).firstIndex(of: ";"),
               let decoded = decodeEntity(text[text.index(after: index)..<semicolon]) {
                output += decoded
                index = text.index(after: semicolon)
                continue
            }
            output.append(character)
            index = text.index(after: index)
        }
        return output
    }

    private static func decodeEntity(_ entity: Substring) -> String? {
        guard entity.first == "#" else { return namedEntities[entity.lowercased()] }
        let digits = entity.dropFirst()
        let value: UInt32?
        if digits.first == "x" || digits.first == "X" {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits)
        }
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }
}
