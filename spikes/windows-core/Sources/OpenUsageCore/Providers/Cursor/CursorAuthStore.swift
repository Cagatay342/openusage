import Foundation

struct CursorAuthState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case sqlite
        case keychain
        /// `cursor-agent`'s plain-JSON credential file (Linux).
        case file
    }

    var accessToken: String?
    var refreshToken: String?
    var source: Source
}

enum CursorAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case sessionExpired
    case tokenExpired
    case readOnlyStore

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Sign in via Cursor app or run `agent login`."
        case .sessionExpired:
            return "Session expired. Sign in via Cursor app or run `agent login`."
        case .tokenExpired:
            return "Token expired. Sign in via Cursor app or run `agent login`."
        case .readOnlyStore:
            return "OpenUsage does not write to Cursor's credential file."
        }
    }
}

struct CursorAuthStore: Sendable {
    static let stateDBPath = WellKnownPaths.cursorStateDBPath
    #if os(Linux)
    /// `cursor-agent` on Linux keeps its OAuth tokens in plain JSON under the XDG config dir; the
    /// desktop app still uses the VS Code state DB. Both are checked so either install works.
    static var cliAuthFilePath: String {
        WellKnownPaths.configHome.appendingPathComponent("cursor/auth.json", isDirectory: false).path
    }
    #endif
    static let accessTokenKey = "cursorAuth/accessToken"
    static let refreshTokenKey = "cursorAuth/refreshToken"
    static let membershipTypeKey = "cursorAuth/stripeMembershipType"
    static let keychainAccessTokenService = "cursor-access-token"
    static let keychainRefreshTokenService = "cursor-refresh-token"
    static let refreshBufferSeconds: TimeInterval = 5 * 60

    var sqlite: SQLiteAccessing
    var keychain: KeychainAccessing
    var files: TextFileAccessing
    var now: @Sendable () -> Date

    init(
        sqlite: SQLiteAccessing = CursorAuthStore.defaultSQLiteAccessor(),
        keychain: KeychainAccessing = CursorAuthStore.defaultKeychainAccessor(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sqlite = sqlite
        self.keychain = keychain
        self.files = files
        self.now = now
    }

    func loadAuthState() -> CursorAuthState? {
        let sqliteAccessToken = readStateValue(Self.accessTokenKey)
        let sqliteRefreshToken = readStateValue(Self.refreshTokenKey)
        let sqliteMembershipType = readStateValue(Self.membershipTypeKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let keychainAccessToken = readKeychainValue(Self.keychainAccessTokenService)
        let keychainRefreshToken = readKeychainValue(Self.keychainRefreshTokenService)

        let hasSQLiteAuth = sqliteAccessToken != nil || sqliteRefreshToken != nil
        let hasKeychainAuth = keychainAccessToken != nil || keychainRefreshToken != nil

        if hasSQLiteAuth {
            let sqliteSubject = Self.tokenSubject(sqliteAccessToken)
            let keychainSubject = Self.tokenSubject(keychainAccessToken)
            let subjectsDiffer = sqliteSubject != nil && keychainSubject != nil && sqliteSubject != keychainSubject
            if hasKeychainAuth, sqliteMembershipType == "free", subjectsDiffer {
                return CursorAuthState(
                    accessToken: keychainAccessToken,
                    refreshToken: keychainRefreshToken,
                    source: .keychain
                )
            }

            return CursorAuthState(
                accessToken: sqliteAccessToken,
                refreshToken: sqliteRefreshToken,
                source: .sqlite
            )
        }

        if hasKeychainAuth {
            return CursorAuthState(
                accessToken: keychainAccessToken,
                refreshToken: keychainRefreshToken,
                source: .keychain
            )
        }

        #if os(Linux)
        // Last, because a desktop Cursor install is the primary source everywhere else; on a headless
        // box the `cursor-agent` CLI file is usually the only one present.
        if let cliState = loadCLIFileAuthState() {
            return cliState
        }
        #endif

        return nil
    }

    #if os(Linux)
    private struct CLIAuthFile: Decodable {
        var accessToken: String?
        var refreshToken: String?
    }

    /// Reads `cursor-agent`'s credential file. Returns nil when it is absent or holds no tokens.
    ///
    /// An absent file is normal — the user simply hasn't signed in. A file that exists but cannot be
    /// read or parsed is a real, fixable problem, so it is logged rather than silently reported as
    /// "not logged in".
    func loadCLIFileAuthState() -> CursorAuthState? {
        let path = Self.cliAuthFilePath
        guard files.exists(path) else { return nil }

        let text: String
        do {
            text = try files.readText(path)
        } catch {
            AppLog.error(LogTag.auth("cursor"), "cannot read \(path): \(error.localizedDescription)")
            return nil
        }
        guard let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(CLIAuthFile.self, from: data)
        else {
            AppLog.error(LogTag.auth("cursor"), "\(path) is not valid cursor-agent credential JSON")
            return nil
        }
        let accessToken = decoded.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let refreshToken = decoded.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard accessToken != nil || refreshToken != nil else { return nil }
        return CursorAuthState(accessToken: accessToken, refreshToken: refreshToken, source: .file)
    }
    #endif

    func needsRefresh(_ accessToken: String?) -> Bool {
        guard let accessToken,
              let expiresAt = Self.tokenExpiration(accessToken)
        else {
            return true
        }
        return expiresAt.timeIntervalSince(now()) <= Self.refreshBufferSeconds
    }

    func saveAccessToken(_ accessToken: String, source: CursorAuthState.Source) throws {
        switch source {
        case .sqlite:
            try writeStateValue(Self.accessTokenKey, accessToken)
        case .keychain:
            try keychain.writeGenericPassword(service: Self.keychainAccessTokenService, value: accessToken)
        case .file:
            // `cursor-agent` owns that file and OpenUsage never writes back to a third-party store.
            // The caller logs this and keeps using the rotated token for the current session.
            throw CursorAuthError.readOnlyStore
        }
    }

    private func readStateValue(_ key: String) -> String? {
        let sql = "SELECT value FROM ItemTable WHERE key = '\(Self.sqlEscaped(key))' LIMIT 1;"
        guard let value = try? sqlite.queryValue(path: Self.stateDBPath, sql: sql) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func writeStateValue(_ key: String, _ value: String) throws {
        let sql = """
        INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('\(Self.sqlEscaped(key))', '\(Self.sqlEscaped(value))');
        """
        try sqlite.execute(path: Self.stateDBPath, sql: sql)
    }

    private func readKeychainValue(_ service: String) -> String? {
        guard let value = try? keychain.readGenericPassword(service: service) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func tokenExpiration(_ token: String) -> Date? {
        guard let exp = ProviderParse.jwtPayload(token)?["exp"].flatMap(ProviderParse.number) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func tokenSubject(_ token: String?) -> String? {
        guard let token,
              let subject = ProviderParse.jwtPayload(token)?["sub"] as? String
        else {
            return nil
        }
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sqlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    static func defaultSQLiteAccessor() -> SQLiteAccessing {
        #if os(Windows)
        WinSQLiteAccessor()
        #elseif os(Linux)
        LinuxSQLiteAccessor()
        #else
        NoOpSQLiteAccessor()
        #endif
    }

    static func defaultKeychainAccessor() -> KeychainAccessing {
        #if os(Windows)
        WindowsCredentialVaultAccessor()
        #else
        NoOpKeychainAccessor()
        #endif
    }
}
