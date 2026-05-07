import Foundation

enum AIProvider: String, CaseIterable, Identifiable, Codable, Hashable {
    case anthropic
    case openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic Claude"
        case .openai:    return "OpenAI ChatGPT"
        }
    }

    var keychainKey: String {
        switch self {
        case .anthropic: return KeychainStore.Key.anthropicAPIKey
        case .openai:    return KeychainStore.Key.openAIAPIKey
        }
    }

    /// Default model to use when generating minutes.
    /// Fast, cheap, plenty smart for structured summaries — users can always upgrade later.
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-haiku-4-5"
        case .openai:    return "gpt-4o-mini"
        }
    }
}
