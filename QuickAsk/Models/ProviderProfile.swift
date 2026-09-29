import Foundation

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case openCodeGo
    case deepSeek
    case openAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openCodeGo: return "OpenCode Go"
        case .deepSeek: return "DeepSeek"
        case .openAICompatible: return "Custom (OpenAI-compatible)"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openCodeGo: return "https://opencode.ai/zen/go/v1"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .openAICompatible: return "https://api.openai.com/v1"
        }
    }

    var defaultModels: [String] {
        switch self {
        case .openCodeGo:
            return [
                "deepseek-v4-flash",
                "deepseek-v4-pro",
                "glm-5.3-flash",
                "kimi-k2.7-code",
                "minimax-m2.7",
                "qwen3.7-plus"
            ]
        case .deepSeek:
            return ["deepseek-chat", "deepseek-reasoner"]
        case .openAICompatible:
            return ["gpt-4o-mini", "gpt-4o"]
        }
    }

    var keychainAccount: String {
        "quickask.apikey.\(rawValue)"
    }
}

struct ProviderProfile: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var kind: ProviderKind
    var baseURL: String
    var model: String
    /// Secret stored in Application Support; flag only tracks whether one was saved.
    var hasAPIKey: Bool

    static func preset(_ kind: ProviderKind, name: String? = nil) -> ProviderProfile {
        ProviderProfile(
            id: UUID(),
            name: name ?? kind.displayName,
            kind: kind,
            baseURL: kind.defaultBaseURL,
            model: kind.defaultModels.first ?? "",
            hasAPIKey: false
        )
    }
}
