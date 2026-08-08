import Foundation

/// Reads API keys Aider stores on disk. Aider's OpenRouter OAuth flow writes
/// `~/.aider/oauth-keys.env`; it also supports `~/.env` and `~/.aider.conf.yml`.
enum AiderConfig {
    static let openRouterCompanionPaths = [
        "~/.aider/oauth-keys.env",
        "~/.env",
        "~/.aider.conf.yml",
    ]

    /// Parse `api-key: - <provider>=<key>` (or a scalar `api-key: <provider>=<key>`) from Aider's YAML.
    static func apiKey(for provider: String, in yaml: String) -> String? {
        let prefix = provider + "="
        var inAPIKeySection = false
        for line in yaml.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("api-key:") {
                inAPIKeySection = true
                let remainder = trimmed.dropFirst("api-key:".count).trimmingCharacters(in: .whitespaces)
                if let key = valueAfterPrefix(remainder, prefix: prefix) { return key }
                continue
            }

            if inAPIKeySection {
                if let first = line.first, !first.isWhitespace, !trimmed.hasPrefix("-") {
                    inAPIKeySection = false
                    continue
                }
                let entry = trimmed.hasPrefix("-")
                    ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                    : trimmed
                if let key = valueAfterPrefix(entry, prefix: prefix) { return key }
            }
        }
        return nil
    }

    private static func valueAfterPrefix(_ text: String, prefix: String) -> String? {
        guard text.hasPrefix(prefix) else { return nil }
        let value = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.nilIfEmpty
    }
}
