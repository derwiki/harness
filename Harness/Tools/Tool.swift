//
//  Tool.swift
//  Harness
//

import Foundation

/// A capability the model can call. To add a tool, create a type that conforms to `Tool`
/// and list it in `ToolRegistry.all`.
protocol Tool {
    /// The function name the model uses to call the tool.
    var name: String { get }
    var description: String { get }
    /// JSON Schema for the arguments object.
    var parameters: JSONValue { get }
    /// Runs the tool with the raw JSON arguments from the model and returns text for the model.
    func run(argumentsJSON: String) async throws -> String
}

enum ToolRegistry {
    static let all: [any Tool] = [
        WebFetchTool(),
        CalendarEventsTool(),
    ]

    static func tool(named name: String) -> (any Tool)? {
        all.first { $0.name == name }
    }

    static var wireDefinitions: [WireTool] {
        all.map { WireTool(function: .init(name: $0.name, description: $0.description, parameters: $0.parameters)) }
    }
}

/// Thrown when a tool cannot parse or accept its arguments. Recorded as a parse failure in telemetry.
struct ToolArgumentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A tool failure that is not about the arguments (for example, permission denied).
struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Decodes tool arguments and converts decoding errors into a readable `ToolArgumentError`.
func decodeToolArguments<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
    do {
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    } catch let DecodingError.keyNotFound(key, _) {
        throw ToolArgumentError(message: "Missing required argument '\(key.stringValue)'.")
    } catch let DecodingError.typeMismatch(_, context) {
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        throw ToolArgumentError(message: "Argument '\(path)' has the wrong type.")
    } catch let DecodingError.valueNotFound(_, context) {
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        throw ToolArgumentError(message: "Argument '\(path)' is null.")
    } catch {
        throw ToolArgumentError(message: "Arguments are not valid JSON.")
    }
}
