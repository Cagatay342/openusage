import Foundation

/// Outcome of reading the local OpenCode credential. `unreadable` is deliberately distinct from
/// `absent`: a present-but-broken `auth.json` is an OpenCode footprint that must surface an actionable
/// error, never be mistaken for "not logged in".
enum OpenCodeCredentialLoad: Sendable, Equatable {
    case key(String)
    case absent
    case unreadable(String)
}

/// Reads the OpenCode Go credential already on the machine. Local-only — never the network. The
/// `opencode-go` key is both the first-run detection signal and the Bearer token for
/// `GET /zen/go/v1/usage`, so it lives behind one loader.
struct OpenCodeAuthStore: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.files = files
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    var dataDirectory: String {
        OpenCodePaths.dataDirectory(environment: environment, homeDirectory: homeDirectory())
    }

    var authFilePath: String {
        OpenCodePaths.authFilePath(dataDirectory: dataDirectory)
    }

    /// Read the non-empty `opencode-go` API key from `auth.json`. Reads only that one entry, so an
    /// unrelated sibling value can't hide a valid key. An absent file is the normal "not logged in"
    /// case; a present file that can't be read or parsed is `unreadable` so broken storage is never
    /// mistaken for logout.
    func loadGoKey() -> OpenCodeCredentialLoad {
        guard files.exists(authFilePath) else { return .absent }
        let text: String
        do {
            text = try files.readText(authFilePath)
        } catch {
            return .unreadable(error.localizedDescription)
        }
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unreadable("auth.json is not valid JSON")
        }
        guard let entry = object["opencode-go"] as? [String: Any],
              let key = (entry["key"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return .absent
        }
        return .key(key)
    }
}
