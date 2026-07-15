import Foundation

/// Tracks pool quota for Antigravity (Google's AI IDE) and the headless `agy` CLI.
///
/// Windows spike: reads the OAuth token from Credential Manager (`gemini:antigravity`) and queries
/// Google's Cloud Code API. Local language-server discovery (running Antigravity IDE / `agy` process)
/// is not wired on Windows yet — see `docs/windows.md`.
@MainActor
final class AntigravityProvider: ProviderRuntime {
    let provider = Provider(id: "antigravity", displayName: "Antigravity", icon: .providerMark("antigravity"))

    let authStore: AntigravityAuthStore
    let usageClient: AntigravityUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: AntigravityAuthStore = AntigravityAuthStore(),
        usageClient: AntigravityUsageClient = AntigravityUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: AntigravityMetric.geminiID, provider: provider, title: AntigravityMetric.sessionLabel, isSessionWindow: true),
            .percent(id: AntigravityMetric.geminiWeeklyID, provider: provider, title: AntigravityMetric.weeklyLabel),
            .percent(id: AntigravityMetric.claudeID, provider: provider, title: AntigravityMetric.claudeLabel, isSessionWindow: true),
            .percent(id: AntigravityMetric.claudeWeeklyID, provider: provider, title: AntigravityMetric.claudeWeeklyLabel)
        ]
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in
            authStore.loadKeychainToken() != nil || authStore.loadCachedToken() != nil
        }
    }

    func refresh() async -> ProviderSnapshot {
        do {
            let result = try await probeCloudCode()
            return ProviderSnapshot.make(provider: provider, plan: result.plan, lines: result.lines, refreshedAt: now())
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private struct StrategyResult {
        var plan: String?
        var lines: [MetricLine]
    }

    // MARK: - Cloud Code

    private func probeCloudCode() async throws -> StrategyResult {
        let authStore = self.authStore
        let keychainToken = await loadOffMainActor { authStore.loadKeychainToken() }

        var tokens: [String] = []
        if let keychainToken, let access = keychainToken.accessToken, authStore.isUsable(expiry: keychainToken.expiry) {
            tokens.append(access)
        }
        if let cached = authStore.loadCachedToken(), !tokens.contains(cached) {
            tokens.append(cached)
        }

        let hasCredentials = !tokens.isEmpty || (keychainToken?.refreshToken?.isEmpty == false)

        var sawAuthFailure = false
        for token in tokens {
            switch await fetchCloudCode(token: token) {
            case .success(let result): return result
            case .authFailed: sawAuthFailure = true
            case .unavailable: break
            }
        }

        if sawAuthFailure || tokens.isEmpty, let refreshToken = keychainToken?.refreshToken {
            switch await usageClient.refreshGoogleToken(refreshToken) {
            case .refreshed(let accessToken, let expiresIn):
                authStore.cacheToken(accessToken, expiresIn: expiresIn)
                switch await fetchCloudCode(token: accessToken) {
                case .success(let result): return result
                case .authFailed: throw AntigravityError.authExpired
                case .unavailable: throw AntigravityError.unavailable
                }
            case .authFailed: throw AntigravityError.authExpired
            case .unavailable: throw AntigravityError.unavailable
            }
        }

        if sawAuthFailure { throw AntigravityError.authExpired }
        if hasCredentials { throw AntigravityError.unavailable }
        throw AntigravityError.notSignedIn
    }

    private enum CloudCodeProbe {
        case success(StrategyResult)
        case authFailed
        case unavailable
    }

    private func fetchCloudCode(token: String) async -> CloudCodeProbe {
        var plan: String?
        var project: String?
        switch await usageClient.cloudCode(path: AntigravityUsageClient.loadCodeAssistPath, token: token, userAgent: "agy", body: [:]) {
        case .authFailed:
            return .authFailed
        case .ok(let data):
            plan = AntigravityUsageMapper.parseLoadCodeAssistPlan(data)
            project = AntigravityUsageMapper.parseProject(data)
        case .unavailable:
            break
        }

        let scopedBody = project.map { ["project": $0] } ?? [:]

        switch await usageClient.cloudCode(path: AntigravityUsageClient.quotaSummaryPath, token: token, userAgent: "antigravity", body: scopedBody) {
        case .authFailed:
            return .authFailed
        case .ok(let data):
            if let lines = AntigravityUsageMapper.parseQuotaSummary(data) {
                return .success(StrategyResult(plan: plan, lines: lines))
            }
        case .unavailable:
            break
        }

        switch await usageClient.cloudCode(path: AntigravityUsageClient.fetchModelsPath, token: token, userAgent: "antigravity", body: scopedBody) {
        case .authFailed:
            return .authFailed
        case .ok(let data):
            let lines = AntigravityUsageMapper.buildLines(AntigravityUsageMapper.parseCloudCodeModels(data))
            if !lines.isEmpty {
                return .success(StrategyResult(plan: plan, lines: lines))
            }
        case .unavailable:
            break
        }

        var quota = await usageClient.cloudCode(
            path: AntigravityUsageClient.retrieveQuotaPath,
            token: token,
            userAgent: "agy",
            body: scopedBody
        )
        if case .unavailable = quota, project != nil {
            quota = await usageClient.cloudCode(path: AntigravityUsageClient.retrieveQuotaPath, token: token, userAgent: "agy", body: [:])
        }
        switch quota {
        case .authFailed: return .authFailed
        case .ok(let data):
            let lines = AntigravityUsageMapper.buildLines(AntigravityUsageMapper.parseQuotaBuckets(data))
            if !lines.isEmpty { return .success(StrategyResult(plan: plan, lines: lines)) }
        case .unavailable: break
        }
        return .unavailable
    }

    private func loadPlan(token: String) async -> String? {
        if case .ok(let data) = await usageClient.cloudCode(path: AntigravityUsageClient.loadCodeAssistPath, token: token, userAgent: "agy", body: [:]) {
            return AntigravityUsageMapper.parseLoadCodeAssistPlan(data)
        }
        return nil
    }
}
