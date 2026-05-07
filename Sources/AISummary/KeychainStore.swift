import Foundation

/// Stores small per-app secrets (API keys). Despite the historical name, this is now
/// UserDefaults-backed rather than Keychain-backed.
///
/// Why: when the app is ad-hoc signed, each rebuild's signature changes, so macOS treats
/// every new build as a "different app" trying to read a keychain item the previous build
/// owned, and prompts the user for their login password each time. UserDefaults is scoped
/// to the app's sandbox container (`~/Library/Containers/com.reviewlite.app/...`) and
/// only readable by ReviewLite itself — sufficient privacy for a personal-use API key,
/// no auth prompts during development.
enum KeychainStore {

    enum Key {
        static let anthropicAPIKey = "anthropic-api-key"
        static let openAIAPIKey = "openai-api-key"
    }

    @discardableResult
    static func set(_ value: String?, for key: String) -> Bool {
        let prefsKey = "apikey-\(key)"
        if let value, !value.isEmpty {
            UserDefaults.standard.set(value, forKey: prefsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: prefsKey)
        }
        return true
    }

    static func get(_ key: String) -> String? {
        let prefsKey = "apikey-\(key)"
        guard let value = UserDefaults.standard.string(forKey: prefsKey),
              !value.isEmpty else { return nil }
        return value
    }

    static func has(_ key: String) -> Bool {
        return get(key) != nil
    }
}
