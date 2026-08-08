import Foundation

/// Minimal `.env` parsing for companion tools (Aider, etc.) that store API keys as `KEY=value` lines.
enum DotEnv {
    /// Read the first matching `name=value` assignment. Ignores comments and blank lines; strips optional
    /// `export ` prefixes and surrounding single/double quotes on the value.
    static func value(named name: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("export ") {
                trimmed = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            guard key == name else { continue }
            var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else { continue }
            return result
        }
        return nil
    }
}
