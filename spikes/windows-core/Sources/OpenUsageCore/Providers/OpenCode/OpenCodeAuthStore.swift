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
/// credential is both the first-run detection signal and the Bearer token for
/// `GET /zen/go/v1/usage`, so it lives behind one loader.
///
/// OpenCode 2 moved credentials from `auth.json` into `opencode.db`'s `credential` table and signs in
/// with an OpenCode account (OAuth) instead of a static Go API key. It imports `auth.json` once and
/// never deletes it, so the file can keep an expired key long after OpenCode itself stopped using it.
/// Lookup order: the unexpired account access token, then the database `opencode-go` key, then
/// `auth.json` (OpenCode 1).
struct OpenCodeAuthStore: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL
    var sqlite: SQLiteAccessing
    var now: @Sendable () -> Date

    /// The active OpenCode account access token, skipped once expired (OpenCode refreshes it on its
    /// next run; OpenUsage never writes to a third-party store).
    static func credentialSQLAccountToken(nowMilliseconds: Int64) -> String {
        """
        SELECT json_extract(value,'$.access')
        FROM credential
        WHERE integration_id = 'opencode' AND (active IS NULL OR active = 1)
          AND json_extract(value,'$.type') = 'oauth'
          AND json_extract(value,'$.expires') > \(nowMilliseconds)
        ORDER BY active DESC, time_updated DESC, id DESC
        LIMIT 1;
        """
    }

    static let credentialSQLGoKey = """
        SELECT json_extract(value,'$.key')
        FROM credential
        WHERE integration_id = 'opencode-go' AND (active IS NULL OR active = 1)
        ORDER BY active DESC, time_updated DESC, id DESC
        LIMIT 1;
        """

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        sqlite: SQLiteAccessing = CursorAuthStore.defaultSQLiteAccessor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.files = files
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.sqlite = sqlite
        self.now = now
    }

    var dataDirectory: String {
        OpenCodePaths.dataDirectory(environment: environment, homeDirectory: homeDirectory())
    }

    var authFilePath: String {
        OpenCodePaths.authFilePath(dataDirectory: dataDirectory)
    }

    var databasePath: String {
        OpenCodePaths.databasePath(dataDirectory: dataDirectory)
    }

    /// Read the non-empty `opencode-go` API key from `auth.json`. Reads only that one entry, so an
    /// unrelated sibling value can't hide a valid key. An absent file is the normal "not logged in"
    /// case; a present file that can't be read or parsed is `unreadable` so broken storage is never
    /// mistaken for logout.
    func loadGoKey() -> OpenCodeCredentialLoad {
        if let credential = loadDatabaseCredential() {
            return .key(credential)
        }
        return loadAuthFileKey()
    }

    /// OpenCode 2's `credential` table. A database that can't be queried (OpenCode 1 schema, missing
    /// `sqlite3`) is logged and falls through to `auth.json`, which OpenCode 1 still uses.
    private func loadDatabaseCredential() -> String? {
        guard files.exists(databasePath) else { return nil }
        let nowMilliseconds = Int64(now().timeIntervalSince1970 * 1000)
        do {
            for sql in [Self.credentialSQLAccountToken(nowMilliseconds: nowMilliseconds), Self.credentialSQLGoKey] {
                if let value = try sqlite.queryValue(path: databasePath, sql: sql)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                    return value
                }
            }
        } catch {
            AppLog.warn(.auth, "OpenCode credential database unreadable, falling back to auth.json: \(error.localizedDescription)")
        }
        return nil
    }

    private func loadAuthFileKey() -> OpenCodeCredentialLoad {
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
