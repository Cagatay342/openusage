import Foundation

/// Where OpenCode keeps its local data, shared by the auth store. Resolution mirrors OpenCode itself:
/// an explicit `OPENCODE_DATA_DIR` wins, then `$XDG_DATA_HOME/opencode`, then the default
/// `~/.local/share/opencode` (which is also where OpenCode puts its data on Windows).
enum OpenCodePaths {
    static func dataDirectory(environment: EnvironmentReading, homeDirectory: URL) -> String {
        if let override = environment.value(for: "OPENCODE_DATA_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return expandHome(override).trimmingTrailingSlashes
        }
        if let xdg = environment.value(for: "XDG_DATA_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return expandHome(xdg).trimmingTrailingSlashes + "/opencode"
        }
        return homeDirectory.appendingPathComponent(".local/share/opencode").path
    }

    static func authFilePath(dataDirectory: String) -> String {
        dataDirectory.trimmingTrailingSlashes + "/auth.json"
    }

    static func databasePath(dataDirectory: String) -> String {
        dataDirectory.trimmingTrailingSlashes + "/opencode.db"
    }
}
