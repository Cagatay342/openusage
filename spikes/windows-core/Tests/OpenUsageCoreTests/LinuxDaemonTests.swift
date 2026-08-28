#if os(Linux)
import XCTest
@testable import OpenUsageCore

/// Regression coverage for the Linux-only seams: XDG paths, the POSIX HTTP transport, and the two
/// credential sources that live in plain files on Linux rather than an OS keyring.
final class LinuxDaemonTests: XCTestCase {

    // MARK: - Well-known paths

    /// `FileManager.urls(for: .libraryDirectory, in: .userDomainMask)` returns an EMPTY array on Linux,
    /// so the macOS `[0]` subscript trapped at launch — the daemon died inside `AppLog.bootstrap()`
    /// before serving anything. These assertions fail by crashing if that regresses.
    func testLocalAppDataResolvesWithoutTrapping() {
        let path = WellKnownPaths.localAppData.path
        XCTAssertFalse(path.isEmpty)
        XCTAssertTrue(path.hasPrefix("/"), "expected an absolute path, got \(path)")
    }

    func testApplicationSupportResolvesWithoutTrapping() {
        let path = WellKnownPaths.applicationSupport.path
        XCTAssertFalse(path.isEmpty)
        XCTAssertTrue(path.hasPrefix("/"), "expected an absolute path, got \(path)")
    }

    func testLocalAppDataDefaultsToXDGStateDirectory() {
        // Only meaningful when the environment leaves it at the spec default.
        try? XCTSkipIf(ProcessInfo.processInfo.environment["XDG_STATE_HOME"]?.hasPrefix("/") == true)
        XCTAssertTrue(
            WellKnownPaths.localAppData.path.hasSuffix(".local/state"),
            "expected the XDG state dir, got \(WellKnownPaths.localAppData.path)"
        )
    }

    /// Linux Cursor keeps VS Code state under XDG config, not the data dir other platforms use.
    func testCursorStateDBPathUsesXDGConfig() {
        XCTAssertTrue(
            WellKnownPaths.cursorStateDBPath.hasSuffix("Cursor/User/globalStorage/state.vscdb"),
            WellKnownPaths.cursorStateDBPath
        )
        XCTAssertTrue(
            WellKnownPaths.cursorStateDBPath.hasPrefix(WellKnownPaths.configHome.path + "/"),
            WellKnownPaths.cursorStateDBPath
        )
    }

    /// The `cursor-agent` credential file must follow the same XDG config dir as the desktop state DB,
    /// or a user with a custom XDG_CONFIG_HOME silently looks logged out.
    func testCursorCLIAuthPathFollowsXDGConfig() {
        XCTAssertEqual(
            CursorAuthStore.cliAuthFilePath,
            WellKnownPaths.configHome.appendingPathComponent("cursor/auth.json").path
        )
    }

    // MARK: - HTTP transport

    func testParseRequestLineReadsMethodAndPath() {
        let parsed = LinuxUsageServer.parseRequestLine("GET /v1/usage HTTP/1.1\r\nHost: localhost")
        XCTAssertEqual(parsed.method, "GET")
        XCTAssertEqual(parsed.path, "/v1/usage")
    }

    /// A malformed or empty head must route to 404, never trap the accept loop.
    func testParseRequestLineToleratesGarbage() {
        XCTAssertEqual(LinuxUsageServer.parseRequestLine("").path, "/")
        XCTAssertEqual(LinuxUsageServer.parseRequestLine("GET").path, "/")
        XCTAssertEqual(LinuxUsageServer.parseRequestLine("").method, "")
        XCTAssertEqual(LinuxUsageServer.parseRequestLine("\r\n\r\n").method, "")
    }

    func testLoopbackDetection() {
        XCTAssertTrue(LinuxUsageServer.isLoopback("127.0.0.1"))
        XCTAssertTrue(LinuxUsageServer.isLoopback("127.1.2.3"))
        XCTAssertTrue(LinuxUsageServer.isLoopback("localhost"))
        XCTAssertFalse(LinuxUsageServer.isLoopback("0.0.0.0"))
        XCTAssertFalse(LinuxUsageServer.isLoopback("192.168.1.10"))
    }

    func testBindAddressValidation() {
        XCTAssertTrue(LinuxUsageServer.isValidBindAddress("127.0.0.1"))
        XCTAssertTrue(LinuxUsageServer.isValidBindAddress("0.0.0.0"))
        XCTAssertTrue(LinuxUsageServer.isValidBindAddress("localhost"))
        XCTAssertFalse(LinuxUsageServer.isValidBindAddress("not-an-ip"))
        XCTAssertFalse(LinuxUsageServer.isValidBindAddress("999.1.1.1"))
        XCTAssertFalse(LinuxUsageServer.isValidBindAddress(""))
    }

    /// No CORS header on any bind. `Access-Control-Allow-Origin: *` on a loopback API would let any
    /// website the user happens to visit read their usage from http://127.0.0.1:6736.
    func testNeverSendsCORSHeaders() {
        let head = LinuxUsageServer.responseHead(for: LocalUsageAPI.Response(status: 200, body: Data("[]".utf8)))
        XCTAssertFalse(head.contains("Access-Control-Allow-Origin"))
        XCTAssertFalse(head.contains("Access-Control-Allow-Methods"))
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(head.contains("Content-Length: 2\r\n"))
    }

    func testResponseHeadOmitsContentTypeWhenBodyless() {
        let head = LinuxUsageServer.responseHead(for: LocalUsageAPI.Response(status: 204, body: nil))
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 204 No Content\r\n"))
        XCTAssertTrue(head.contains("Content-Length: 0\r\n"))
        XCTAssertFalse(head.contains("\r\nContent-Type:"))
    }

    // MARK: - Serving a provider whose refresh failed

    private var provider: Provider { Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude")) }

    private func goodSnapshot() -> ProviderSnapshot {
        ProviderSnapshot.make(
            provider: provider,
            plan: "Max 20x",
            lines: [.progress(label: "Weekly", used: 93, limit: 100, format: .percent)],
            refreshedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    /// A transient failure must not blank the dashboard, but the card must not look current either.
    func testFailedRefreshKeepsLastGoodDataAndShowsAnError() throws {
        let failure = ProviderSnapshot.error(provider: provider, message: "Claude auth expired", category: .authExpired)
        let served = OpenUsageLinuxDaemon.servedSnapshot(lastGood: goodSnapshot(), failure: failure)

        XCTAssertEqual(served.plan, "Max 20x")
        XCTAssertEqual(served.lines.filter { !$0.isError }.count, 1, "last good metrics must survive")
        let errors = served.lines.filter(\.isError)
        XCTAssertEqual(errors.count, 1)
        if case .badge(_, let text, _, _) = try XCTUnwrap(errors.first) {
            XCTAssertEqual(text, "Claude auth expired")
        } else {
            XCTFail("expected an error badge")
        }
    }

    /// Repeated failures rebuild from the untouched last-good snapshot, so badges never stack up.
    func testRepeatedFailuresDoNotAccumulateBadges() {
        let lastGood = goodSnapshot()
        let failure = ProviderSnapshot.error(provider: provider, message: "boom", category: .other)
        _ = OpenUsageLinuxDaemon.servedSnapshot(lastGood: lastGood, failure: failure)
        let second = OpenUsageLinuxDaemon.servedSnapshot(lastGood: lastGood, failure: failure)
        XCTAssertEqual(second.lines.filter(\.isError).count, 1)
    }

    /// With nothing cached there is nothing to preserve, so the error snapshot is served as-is.
    func testFailureWithNoCachedDataServesTheErrorSnapshot() {
        let failure = ProviderSnapshot.error(provider: provider, message: "boom", category: .other)
        let served = OpenUsageLinuxDaemon.servedSnapshot(lastGood: nil, failure: failure)
        XCTAssertEqual(served.errorCategory, .other)
        XCTAssertTrue(served.lines.allSatisfy(\.isError))
    }

    // MARK: - Cursor credentials (cursor-agent CLI file)

    func testCursorReadsCLIAuthFileWhenStateDBHasNoTokens() throws {
        let files = FakeFiles([
            CursorAuthStore.cliAuthFilePath: #"{"accessToken":"access-1","refreshToken":"refresh-1"}"#
        ])
        let store = CursorAuthStore(sqlite: NoOpSQLiteAccessor(), keychain: FakeKeychain(), files: files)

        let state = try XCTUnwrap(store.loadAuthState())
        XCTAssertEqual(state.accessToken, "access-1")
        XCTAssertEqual(state.refreshToken, "refresh-1")
        XCTAssertEqual(state.source, .file)
    }

    func testCursorIgnoresCLIAuthFileWithoutTokens() {
        let files = FakeFiles([CursorAuthStore.cliAuthFilePath: #"{"accessToken":"","refreshToken":null}"#])
        let store = CursorAuthStore(sqlite: NoOpSQLiteAccessor(), keychain: FakeKeychain(), files: files)
        XCTAssertNil(store.loadAuthState())
    }

    /// `cursor-agent` owns that file, so a rotated token is used for the session but never written back.
    func testCursorRefusesToWriteBackToCLIAuthFile() {
        let store = CursorAuthStore(sqlite: NoOpSQLiteAccessor(), keychain: FakeKeychain(), files: FakeFiles())
        XCTAssertThrowsError(try store.saveAccessToken("rotated", source: .file)) { error in
            XCTAssertEqual(error as? CursorAuthError, .readOnlyStore)
        }
    }

    // MARK: - Antigravity credentials (agy CLI file)

    /// On Linux `agy` has no OS keyring, so it writes the OAuth token as plain JSON under ~/.gemini.
    func testAntigravityReadsLinuxTokenFile() throws {
        let json = """
        {"token":{"access_token":"agy-access","token_type":"Bearer","refresh_token":"agy-refresh",\
        "expiry":"2030-01-01T00:00:00Z"},"auth_method":"oauth"}
        """
        let store = AntigravityAuthStore(
            keychain: FakeKeychain(),
            files: FakeFiles([AntigravityAuthStore.linuxTokenFilePath: json])
        )

        let token = try XCTUnwrap(store.loadKeychainToken())
        XCTAssertEqual(token.accessToken, "agy-access")
        XCTAssertEqual(token.refreshToken, "agy-refresh")
        XCTAssertEqual(token.expiry, OpenUsageISO8601.date(from: "2030-01-01T00:00:00Z"))
    }

    func testAntigravityFallsBackToKeychainWhenNoTokenFile() throws {
        let store = AntigravityAuthStore(
            keychain: FakeKeychain(#"{"access_token":"from-keyring"}"#),
            files: FakeFiles()
        )
        let token = try XCTUnwrap(store.loadKeychainToken())
        XCTAssertEqual(token.accessToken, "from-keyring")
    }

    func testAntigravityIgnoresUnparsableTokenFile() {
        let store = AntigravityAuthStore(
            keychain: FakeKeychain(),
            files: FakeFiles([AntigravityAuthStore.linuxTokenFilePath: "not json"])
        )
        XCTAssertNil(store.loadKeychainToken())
    }

    // MARK: - Token authentication

    private let token = "s3cret-token"

    func testAcceptsBearerHeader() {
        let head = "GET /v1/usage HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer \(token)"
        XCTAssertEqual(LinuxUsageServer.authorization(head: head, path: "/v1/usage", token: token), .accepted)
    }

    func testAcceptsQueryParameterAndSignalsCookieIssue() {
        let head = "GET /?token=\(token) HTTP/1.1\r\nHost: x"
        XCTAssertEqual(
            LinuxUsageServer.authorization(head: head, path: "/?token=\(token)", token: token),
            .acceptedFromQuery
        )
    }

    func testAcceptsCookieSetByAnEarlierDashboardLoad() {
        let head = "GET /v1/usage HTTP/1.1\r\nCookie: other=1; \(LinuxUsageServer.tokenCookieName)=\(token)"
        XCTAssertEqual(LinuxUsageServer.authorization(head: head, path: "/v1/usage", token: token), .accepted)
    }

    func testRejectsMissingOrWrongToken() {
        XCTAssertEqual(
            LinuxUsageServer.authorization(head: "GET /v1/usage HTTP/1.1\r\nHost: x", path: "/v1/usage", token: token),
            .rejected
        )
        XCTAssertEqual(
            LinuxUsageServer.authorization(
                head: "GET /v1/usage HTTP/1.1\r\nAuthorization: Bearer wrong",
                path: "/v1/usage",
                token: token
            ),
            .rejected
        )
        XCTAssertEqual(
            LinuxUsageServer.authorization(head: "GET /?token=wrong HTTP/1.1", path: "/?token=wrong", token: token),
            .rejected
        )
    }

    /// A prefix of the real token must not authenticate.
    func testRejectsTokenPrefix() {
        let head = "GET /v1/usage HTTP/1.1\r\nAuthorization: Bearer \(token.dropLast())"
        XCTAssertEqual(LinuxUsageServer.authorization(head: head, path: "/v1/usage", token: token), .rejected)
    }

    /// `/?token=<secret>` is a supported way to open the dashboard, and the log file outlives the
    /// request — so the query must never reach it.
    func testRequestLogRedactsTheQueryString() {
        XCTAssertEqual(LinuxUsageServer.redactingQuery("/?token=\(token)"), "/?<redacted>")
        XCTAssertEqual(LinuxUsageServer.redactingQuery("/v1/usage?token=\(token)&x=1"), "/v1/usage?<redacted>")
        XCTAssertFalse(LinuxUsageServer.redactingQuery("/?token=\(token)").contains(token))
        // Paths without a query are untouched.
        XCTAssertEqual(LinuxUsageServer.redactingQuery("/v1/usage/claude"), "/v1/usage/claude")
        XCTAssertEqual(LinuxUsageServer.redactingQuery("/"), "/")
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(LinuxUsageServer.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(LinuxUsageServer.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(LinuxUsageServer.constantTimeEquals("abc", "ab"))
        XCTAssertFalse(LinuxUsageServer.constantTimeEquals("", "a"))
        XCTAssertTrue(LinuxUsageServer.constantTimeEquals("", ""))
    }

    func testUnauthorizedResponseIsJSON401() {
        XCTAssertEqual(LinuxUsageServer.unauthorized.status, 401)
        XCTAssertEqual(LinuxUsageServer.reasonPhrase(for: 401), "Unauthorized")
        XCTAssertEqual(
            LinuxUsageServer.unauthorized.body.map { String(decoding: $0, as: UTF8.self) },
            #"{"error":"unauthorized"}"#
        )
    }

    func testSetCookieHeaderIsEmittedWhenAsked() {
        let head = LinuxUsageServer.responseHead(
            for: LocalUsageAPI.Response(status: 200, body: Data("x".utf8)),
            extraHeaders: ["Set-Cookie: \(LinuxUsageServer.tokenCookieName)=\(token); Path=/; HttpOnly; SameSite=Strict"]
        )
        XCTAssertTrue(head.contains("Set-Cookie: \(LinuxUsageServer.tokenCookieName)=\(token)"))
        XCTAssertTrue(head.contains("HttpOnly"))
    }
}
#endif
