import Foundation

struct OpenRouterAuth: Hashable, Sendable {
    var apiKey: String
}

enum OpenRouterAuthError: Error, LocalizedError, Equatable {
    case missingKey
    case invalidKey
    case saveFailed
    case deleteFailed

    init(_ failure: UserAPIKeyStore.Failure) {
        switch failure {
        case .missingKey: self = .missingKey
        case .saveFailed: self = .saveFailed
        case .deleteFailed: self = .deleteFailed
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No OpenRouter API key. Add one in Settings, set OPENROUTER_API_KEY, or sign in via Aider."
        case .invalidKey:
            return "OpenRouter API key invalid. Check your key at openrouter.ai/keys."
        case .saveFailed:
            return "Couldn't save the OpenRouter API key."
        case .deleteFailed:
            return "Couldn't remove the saved OpenRouter API key."
        }
    }
}

/// Reads an OpenRouter API key the user has already placed on the machine — OpenUsage's config file,
/// Aider's `~/.aider/oauth-keys.env` / `.env` / `.aider.conf.yml`, or an environment variable. A GUI
/// app launched from Finder/Dock doesn't inherit the interactive shell environment, so
/// `ProcessEnvironmentReader` captures the login shell's environment at launch (see
/// `LoginShellEnvironment`) — meaning an env var exported in a shell profile is honored even in a
/// packaged build; the config file remains the explicit path.
struct OpenRouterAuthStore: Sendable {
    /// Config files checked in order; first readable key wins. JSON (`apiKey` / `api_key` / `key`) or a
    /// plain-text file containing only the key.
    static let configPaths = [
        "~/.config/openusage/openrouter.json",
        "~/.config/openrouter/key.json"
    ]
    /// Environment variables checked in order. `OPENROUTER_API_KEY` is the de-facto standard.
    static let environmentNames = ["OPENROUTER_API_KEY", "OPENROUTER_KEY"]

    private let store: UserAPIKeyStore

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        store = UserAPIKeyStore(
            configPaths: Self.configPaths,
            environmentNames: Self.environmentNames,
            files: files,
            environment: environment,
            makeError: { OpenRouterAuthError($0) },
            companionConfigPaths: AiderConfig.openRouterCompanionPaths,
            companionYAMLProvider: "openrouter"
        )
    }

    func loadAPIKey() -> OpenRouterAuth? { store.loadKey().map(OpenRouterAuth.init(apiKey:)) }
    func currentAPIKey() -> String? { store.loadKey() }
    func keyStatus() -> APIKeyStatus { store.keyStatus() }
    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }
}
