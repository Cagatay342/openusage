import XCTest
@testable import OpenUsage

private let openCodeUsageJSON = #"""
{
  "usage": {
    "rolling": { "status": "ok", "percent": 12, "resetsAt": "2026-08-22T17:00:00.000Z" },
    "weekly":  { "status": "ok", "percent": 34, "resetsAt": "2026-08-24T00:00:00.000Z" },
    "monthly": { "status": "rate-limited", "percent": 56, "resetsAt": "2026-09-10T11:54:35.000Z" }
  }
}
"""#

private func openCodeResponse(_ json: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: [:], body: Data(json.utf8))
}

private func makeOpenCodeAuthStore(
    key: String? = nil,
    file contents: String? = nil
) -> OpenCodeAuthStore {
    let files = FakeFiles()
    let store = OpenCodeAuthStore(
        files: files,
        environment: FakeEnvironment(),
        homeDirectory: { URL(fileURLWithPath: "/home/test") }
    )
    if let contents {
        files.files[store.authFilePath] = contents
    } else if let key {
        files.files[store.authFilePath] = "{\"opencode-go\":{\"type\":\"api\",\"key\":\"\(key)\"}}"
    }
    return store
}

// MARK: - OpenCodeAuthStoreTests

final class OpenCodeAuthStoreTests: XCTestCase {
    func testReadsGoKeyFromAuthJSON() {
        let store = makeOpenCodeAuthStore(key: "oc-key")
        XCTAssertEqual(store.loadGoKey(), .key("oc-key"))
    }

    func testAbsentWhenNoFile() {
        XCTAssertEqual(makeOpenCodeAuthStore().loadGoKey(), .absent)
    }

    func testAbsentWhenNoGoEntry() {
        let store = makeOpenCodeAuthStore(file: #"{"openai":{"type":"oauth","access":"a","refresh":"r"}}"#)
        XCTAssertEqual(store.loadGoKey(), .absent)
    }

    func testUnreadableOnInvalidJSON() {
        let store = makeOpenCodeAuthStore(file: "not json")
        guard case .unreadable = store.loadGoKey() else {
            return XCTFail("expected unreadable")
        }
    }

    func testHonorsOpenCodeDataDirOverride() {
        let files = FakeFiles()
        let store = OpenCodeAuthStore(
            files: files,
            environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/custom/oc"]),
            homeDirectory: { URL(fileURLWithPath: "/home/test") }
        )
        files.files["/custom/oc/auth.json"] = #"{"opencode-go":{"type":"api","key":"custom-key"}}"#

        XCTAssertEqual(store.loadGoKey(), .key("custom-key"))
    }
}

// MARK: - OpenCodeUsageMapperTests

final class OpenCodeUsageMapperTests: XCTestCase {
    func testMapsThreeWindowsToPercentMeters() throws {
        let lines = try OpenCodeUsageMapper.meterLines(openCodeResponse(openCodeUsageJSON))

        let session = try XCTUnwrap(progress(lines, "Session"))
        XCTAssertEqual(session.used, 12, accuracy: 0.001)
        XCTAssertEqual(session.limit, 100)
        XCTAssertEqual(session.format, .percent)
        XCTAssertEqual(session.periodDurationMs, 5 * 60 * 60 * 1000)
        XCTAssertEqual(session.resetsAt?.timeIntervalSince1970 ?? 0, 1_787_418_000, accuracy: 0.5)

        XCTAssertEqual(try XCTUnwrap(progress(lines, "Weekly")).used, 34, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(progress(lines, "Weekly")).periodDurationMs, 7 * 24 * 60 * 60 * 1000)

        let monthly = try XCTUnwrap(progress(lines, "Monthly"))
        XCTAssertEqual(monthly.used, 56, accuracy: 0.001)
        XCTAssertEqual(monthly.periodDurationMs, 30 * 24 * 60 * 60 * 1000)
    }

    func testMissingUsageThrowsInvalidResponse() {
        XCTAssertThrowsError(try OpenCodeUsageMapper.meterLines(openCodeResponse(#"{"foo":1}"#))) { error in
            XCTAssertEqual(error as? OpenCodeUsageError, .invalidResponse)
        }
    }

    func testErrorTypeReadsEntitlementError() {
        let body = #"{"type":"error","error":{"type":"EntitlementError","message":"OpenCode Go subscription required."}}"#
        XCTAssertEqual(OpenCodeUsageMapper.errorType(in: openCodeResponse(body)), "EntitlementError")
    }

    private func progress(
        _ lines: [MetricLine], _ label: String
    ) -> (used: Double, limit: Double, format: ProgressFormat, resetsAt: Date?, periodDurationMs: Int?)? {
        guard case .progress(_, let used, let limit, let format, let resetsAt, let period, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit, format, resetsAt, period)
    }
}

// MARK: - OpenCodeProviderTests

@MainActor
final class OpenCodeProviderTests: XCTestCase {
    func testRefreshMapsGoWindows() async {
        let provider = OpenCodeProvider(
            authStore: makeOpenCodeAuthStore(key: "oc-key"),
            usageClient: OpenCodeUsageClient(http: RoutingHTTPClient { request in
                XCTAssertEqual(request.headers["Authorization"], "Bearer oc-key")
                return openCodeResponse(openCodeUsageJSON)
            }),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
        XCTAssertNotNil(snapshot.line(label: "Monthly"))
    }

    func testRefreshWithoutKeyReportsNotLoggedIn() async {
        let provider = OpenCodeProvider(
            authStore: makeOpenCodeAuthStore(),
            usageClient: OpenCodeUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("should not hit the network without a key")
                return openCodeResponse("{}")
            })
        )

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testRefreshOnUnauthorizedReportsAuthInvalid() async {
        let provider = OpenCodeProvider(
            authStore: makeOpenCodeAuthStore(key: "bad"),
            usageClient: OpenCodeUsageClient(http: RoutingHTTPClient { _ in
                openCodeResponse(#"{"type":"error","error":{"type":"AuthError","message":"Unauthorized"}}"#, status: 401)
            })
        )

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
    }

    func testRefreshWithoutGoSubscriptionReportsNotAvailable() async {
        let provider = OpenCodeProvider(
            authStore: makeOpenCodeAuthStore(key: "oc-key"),
            usageClient: OpenCodeUsageClient(http: RoutingHTTPClient { _ in
                openCodeResponse(
                    #"{"type":"error","error":{"type":"EntitlementError","message":"OpenCode Go subscription required."}}"#,
                    status: 403
                )
            })
        )

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .notAvailable)
    }

    func testRefreshOnTransportErrorReportsNetwork() async {
        let provider = OpenCodeProvider(
            authStore: makeOpenCodeAuthStore(key: "oc-key"),
            usageClient: OpenCodeUsageClient(http: RoutingHTTPClient { _ in
                throw HTTPClientError.invalidResponse
            })
        )

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .network)
    }

    func testHasLocalCredentials() async {
        let present = OpenCodeProvider(authStore: makeOpenCodeAuthStore(key: "oc-key"))
        let presentResult = await present.hasLocalCredentials()
        XCTAssertTrue(presentResult)

        let unreadable = OpenCodeProvider(authStore: makeOpenCodeAuthStore(file: "not json"))
        let unreadableResult = await unreadable.hasLocalCredentials()
        XCTAssertTrue(unreadableResult)

        let absent = OpenCodeProvider(authStore: makeOpenCodeAuthStore())
        let absentResult = await absent.hasLocalCredentials()
        XCTAssertFalse(absentResult)
    }

    func testProviderIdentityAndDescriptors() {
        let provider = OpenCodeProvider()
        XCTAssertEqual(provider.provider.id, "opencode")
        XCTAssertEqual(provider.provider.displayName, "OpenCode")
        XCTAssertEqual(provider.widgetDescriptors.map(\.id),
                       ["opencode.session", "opencode.weekly", "opencode.monthly"])
    }
}
