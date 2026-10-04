//
//  ModelCatalog.swift
//  Harness
//

import Foundation

/// A model the user can pick when starting a chat.
struct ModelOption: Identifiable, Hashable {
    /// The OpenRouter model slug.
    let id: String
    let name: String
    /// Some endpoints reject `reasoning.effort = "none"` because reasoning is mandatory.
    let canDisableReasoning: Bool
}

enum ModelCatalog {
    /// Preset models. Each has tool-capable zero-data-retention endpoints on OpenRouter.
    static let presets: [ModelOption] = [
        ModelOption(id: "qwen/qwen3.8-2.4t-a95b", name: "Qwen 3.8", canDisableReasoning: false),
        ModelOption(id: "z-ai/glm-5.3", name: "GLM 5.3", canDisableReasoning: false),
        ModelOption(id: "moonshotai/kimi-k3", name: "Kimi K3", canDisableReasoning: true),
        ModelOption(id: "deepseek/deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash", canDisableReasoning: true),
    ]

    static func preset(for slug: String) -> ModelOption? {
        presets.first { $0.id == slug }
    }

    /// The option for any slug. Unknown slugs (from Settings) display the slug and allow every effort.
    static func option(for slug: String) -> ModelOption {
        preset(for: slug) ?? ModelOption(id: slug, name: slug, canDisableReasoning: true)
    }
}

enum ReasoningEffort: String, CaseIterable, Identifiable {
    /// Omit the `reasoning` field and use the provider's default.
    case `default`
    case none
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default: "Default"
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    /// The value sent as `reasoning.effort`, or nil to omit the field.
    var wireValue: String? {
        self == .default ? nil : rawValue
    }

    static func allowed(for model: ModelOption) -> [ReasoningEffort] {
        model.canDisableReasoning ? allCases : allCases.filter { $0 != .none }
    }
}
