import Foundation

/// Typed failures for the OpenCode provider, so telemetry groups them by a stable category
/// (see `ErrorCategory.swift`).
enum OpenCodeUsageError: Error, LocalizedError, Equatable {
    case notLoggedIn
    /// `auth.json` exists but could not be read or parsed — broken storage, not logout. `detail`
    /// carries the underlying cause for the log file; the user-facing description stays friendly.
    case credentialsUnreadable(detail: String)
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    /// The local Go key was rejected (HTTP 401 / `AuthError`).
    case unauthorized
    /// Valid key, but this account has no Go subscription (HTTP 403 / `EntitlementError`).
    case noGoSubscription

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "OpenCode not detected. Log in with OpenCode Go first."
        case .credentialsUnreadable:
            return "Couldn't read OpenCode's auth.json. Check its file permissions or log into OpenCode Go again."
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        case .unauthorized:
            return "OpenCode Go key was rejected. Log into OpenCode Go again."
        case .noGoSubscription:
            return "No OpenCode Go subscription on this key."
        }
    }
}

/// Tracks OpenCode Go plan usage: the rolling 5-hour, weekly, and monthly quota windows from
/// OpenCode's official usage API (`GET /zen/go/v1/usage`), using the local `opencode-go` API key.
@MainActor
final class OpenCodeProvider: ProviderRuntime {
    let provider = Provider(
        id: "opencode",
        displayName: "OpenCode",
        icon: .providerMark("opencode"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://opencode.ai/auth")
        ]
    )

    let authStore: OpenCodeAuthStore
    let usageClient: OpenCodeUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: OpenCodeAuthStore = OpenCodeAuthStore(),
        usageClient: OpenCodeUsageClient = OpenCodeUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "opencode.session", provider: provider, title: "Session", isSessionWindow: true),
            .percent(id: "opencode.weekly", provider: provider, title: "Weekly"),
            .percent(id: "opencode.monthly", provider: provider, title: "Monthly")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: the local `opencode-go` key. An unreadable auth.json is itself an
        // OpenCode footprint — enable the provider so `refresh()` can surface the actionable error.
        switch await loadOffMainActor({ [authStore] in authStore.loadGoKey() }) {
        case .key, .unreadable:
            return true
        case .absent:
            return false
        }
    }

    func refresh() async -> ProviderSnapshot {
        switch await loadOffMainActor({ [authStore] in authStore.loadGoKey() }) {
        case .unreadable(let detail):
            return ProviderSnapshot.error(
                provider: provider, error: OpenCodeUsageError.credentialsUnreadable(detail: detail)
            )
        case .absent:
            return ProviderSnapshot.error(provider: provider, error: OpenCodeUsageError.notLoggedIn)
        case .key(let apiKey):
            return await fetch(apiKey: apiKey)
        }
    }

    private func fetch(apiKey: String) async -> ProviderSnapshot {
        let response: HTTPResponse
        do {
            response = try await usageClient.fetchUsage(apiKey: apiKey)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: OpenCodeUsageError.connectionFailed)
        }

        if response.statusCode == 401 {
            return ProviderSnapshot.error(provider: provider, error: OpenCodeUsageError.unauthorized)
        }
        if response.statusCode == 403, OpenCodeUsageMapper.errorType(in: response) == "EntitlementError" {
            return ProviderSnapshot.error(provider: provider, error: OpenCodeUsageError.noGoSubscription)
        }
        guard (200..<300).contains(response.statusCode) else {
            return ProviderSnapshot.error(
                provider: provider, error: OpenCodeUsageError.requestFailed(response.statusCode)
            )
        }
        do {
            let lines = try OpenCodeUsageMapper.meterLines(response)
            return ProviderSnapshot.make(provider: provider, plan: "Go", lines: lines, refreshedAt: now())
        } catch let error as OpenCodeUsageError {
            return ProviderSnapshot.error(provider: provider, error: error)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: OpenCodeUsageError.invalidResponse)
        }
    }
}
