#if os(Linux)
import Foundation

/// Headless Linux entry point: probes which providers have credentials on this machine, refreshes them
/// on a timer, and serves the same `/v1/usage` JSON and bundled dashboard the macOS app serves.
public enum OpenUsageLinuxDaemon {
    /// Same port the macOS app's local API uses, so existing clients and bookmarks keep working.
    public static let defaultPort: UInt16 = 6736

    /// Loopback by default: usage data is personal, and only a loopback bind is safe without a token.
    public static let defaultBindAddress = "127.0.0.1"

    /// True when the string is an IPv4 address the daemon can bind.
    public static func isValidBindAddress(_ address: String) -> Bool {
        LinuxUsageServer.isValidBindAddress(address)
    }

    /// True when only processes on this machine could reach a listener on this address.
    public static func isLoopbackAddress(_ address: String) -> Bool {
        LinuxUsageServer.isLoopback(address)
    }

    /// Default provider order matches the macOS app: the established three first, then alphabetically.
    @MainActor
    private static func makeRuntimes() -> [(id: String, runtime: any ProviderRuntime)] {
        [
            ("claude", ClaudeProvider()),
            ("codex", CodexProvider()),
            ("cursor", CursorProvider()),
            ("antigravity", AntigravityProvider()),
            ("grok", GrokProvider()),
            ("openrouter", OpenRouterProvider()),
            ("zai", ZAIProvider())
        ]
    }

    /// What to serve for a provider whose refresh just failed.
    ///
    /// Keeps the last good metrics — a transient failure must not blank the dashboard — but carries the
    /// error badge next to them so a stale card never passes for a current one. The macOS app shows this
    /// through a separate `providerErrors` channel that the shared HTTP API does not expose; here the
    /// dashboard is the only UI, so the error has to ride along in `lines`. A dedicated error field on
    /// `LocalUsageAPI` would be the cleaner fix, but that is a change to both platforms.
    ///
    /// `lastGood` only ever holds successful snapshots, so repeated failures cannot stack up badges.
    static func servedSnapshot(lastGood: ProviderSnapshot?, failure: ProviderSnapshot) -> ProviderSnapshot {
        guard var merged = lastGood else { return failure }
        merged.lines.append(contentsOf: failure.lines.filter(\.isError))
        return merged
    }

    /// Writes one status line to stdout. Swift's `print` is block-buffered once stdout is a pipe — a
    /// systemd journal or a log file — which would hold the daemon's output back for minutes. Writing
    /// through the file handle lands each line immediately.
    private static func emit(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    @MainActor
    public static func run(
        port: UInt16 = defaultPort,
        bindAddress: String = defaultBindAddress,
        interval: TimeInterval = 300,
        token: String? = nil
    ) async {
        AppLog.bootstrap()

        let runtimes = makeRuntimes()
        let knownIDs = Set(runtimes.map(\.id))

        let box = UsageStateBox()
        let server = LinuxUsageServer(box: box, port: port, bindAddress: bindAddress, token: token)
        do {
            try server.start()
        } catch {
            // Fail loudly: a taken port or bad address must be diagnosable, not a silently dead feature.
            AppLog.error(.localAPI, "Linux usage server failed to start: \(error)")
            FileHandle.standardError.write(Data("FATAL: \(error)\n".utf8))
            exit(1)
        }

        emit("OpenUsage daemon listening on http://\(bindAddress):\(port)")
        if !server.isLoopbackOnly {
            // A token is mandatory here (the CLI refuses otherwise), so say how to actually use it and
            // keep pointing at the tunnel, which exposes nothing.
            emit("""

                Bound to \(bindAddress), not loopback: this listener is reachable from other machines.
                Every request must carry the token — open http://\(bindAddress):\(port)/?token=<token>
                in a browser, or send `Authorization: Bearer <token>`.
                Exposing nothing at all is still safer:
                    ssh -N -L \(port):127.0.0.1:\(port) <user>@<this-host>

                """)
            AppLog.warn(.localAPI, "Serving on non-loopback address \(bindAddress):\(port)")
        }

        emit("Probing local credentials…")
        var enabled: [String] = []
        for (id, runtime) in runtimes where await runtime.hasLocalCredentials() {
            enabled.append(id)
        }
        emit("Providers with credentials: \(enabled.isEmpty ? "(none)" : enabled.joined(separator: ", "))")
        box.write(LocalUsageAPI.State(enabledOrderedIDs: enabled, knownIDs: knownIDs, snapshots: [:]))

        /// Only successful refreshes, never mutated by a failure — the source the served view is rebuilt
        /// from, so consecutive failures can't accumulate badges.
        var lastGood: [String: ProviderSnapshot] = [:]
        var served: [String: ProviderSnapshot] = [:]

        while true {
            var succeeded = 0
            var failed: [String] = []
            for (id, runtime) in runtimes where enabled.contains(id) {
                let snapshot = await runtime.refresh()
                if snapshot.errorCategory == nil {
                    lastGood[id] = snapshot
                    served[id] = snapshot
                    succeeded += 1
                    continue
                }

                let reason = snapshot.errorCategory.map(\.rawValue) ?? "error"
                failed.append(id)
                emit("  \(id): refresh failed — \(reason)")
                AppLog.error(LogTag.plugin(id), "Refresh failed: \(reason)")

                served[id] = servedSnapshot(lastGood: lastGood[id], failure: snapshot)
            }
            box.write(LocalUsageAPI.State(enabledOrderedIDs: enabled, knownIDs: knownIDs, snapshots: served))
            // Report this pass, not the cache: a provider whose refresh just failed is still served from
            // its last good snapshot, and counting that as "ok" would hide the failure entirely.
            if failed.isEmpty {
                emit("Refreshed \(succeeded)/\(enabled.count) provider(s) — next pass in \(Int(interval))s")
            } else {
                emit("""
                    Refreshed \(succeeded)/\(enabled.count) provider(s); \(failed.joined(separator: ", ")) \
                    failed and are being served from cached data — next pass in \(Int(interval))s
                    """)
            }
            try? await Task.sleep(for: .seconds(interval))
        }
    }
}
#endif
