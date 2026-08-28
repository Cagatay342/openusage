#if os(Linux)
import Foundation

/// Collects the two pipe drains that run on separate queues.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutput = Data()
    private var standardError = Data()

    func store(_ data: Data, isError: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isError { standardError = data } else { standardOutput = data }
    }

    func read() -> (output: Data, error: Data) {
        lock.lock(); defer { lock.unlock() }
        return (standardOutput, standardError)
    }
}

/// Read-only SQLite access through the `sqlite3` CLI, mirroring the macOS app's `SQLiteCLIAccessor`.
/// Linux ships no bundled SQLite the way Windows has `winsqlite3.dll`, and linking libsqlite3 would add
/// a build-time dependency, so the daemon shells out to the same tool the macOS app already relies on.
///
/// Writes stay disabled, matching the Windows spike: OpenUsage never writes back to a third-party store.
struct LinuxSQLiteAccessor: SQLiteAccessing {
    private static let candidatePaths = ["/usr/bin/sqlite3", "/usr/local/bin/sqlite3", "/bin/sqlite3"]
    private static let queryTimeout: TimeInterval = 5

    /// Resolved once per process, so a missing `sqlite3` is reported once rather than on every refresh.
    private static let executable: String? = {
        let fileManager = FileManager.default
        var candidates = candidatePaths
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates += path.split(separator: ":").map { "\($0)/sqlite3" }

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        AppLog.warn(
            .subprocess,
            "sqlite3 not found on PATH — Cursor's state DB cannot be read. Install it with `sudo apt install sqlite3`."
        )
        return nil
    }()

    func queryValue(path: String, sql: String) throws -> String? {
        guard let executable = Self.executable else {
            throw SQLiteError.queryFailed("sqlite3 is not installed — install it to read Cursor's state DB.")
        }
        let result = try Self.run(
            executable: executable,
            arguments: [
                "-batch",
                "-noheader",
                // Never mutate a third-party database, and keep a running Cursor from blocking the read.
                "-readonly",
                "-cmd", ".timeout 1000",
                WellKnownPaths.expandHome(path),
                sql
            ]
        )
        guard result.code == 0 else {
            throw SQLiteError.queryFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func execute(path: String, sql: String) throws {
        throw SQLiteError.readOnly
    }

    private static func run(executable: String, arguments: [String]) throws -> (stdout: String, stderr: String, code: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = [:]

        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        process.standardInput = FileHandle.nullDevice

        try process.run()

        // A wedged query must not hang the refresh loop forever.
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + queryTimeout, execute: watchdog)

        // Drain both pipes *concurrently*: reading one to EOF first would deadlock whenever the child
        // fills the other pipe's buffer (64 KiB) and blocks before exiting.
        let drain = DispatchGroup()
        let collected = OutputBox()
        for (handle, isError) in [(output.fileHandleForReading, false), (errorOutput.fileHandleForReading, true)] {
            DispatchQueue.global(qos: .utility).async(group: drain) {
                let data = handle.readDataToEndOfFile()
                collected.store(data, isError: isError)
            }
        }
        drain.wait()
        process.waitUntilExit()
        watchdog.cancel()

        let (outputData, errorData) = collected.read()

        return (
            String(decoding: outputData, as: UTF8.self),
            String(decoding: errorData, as: UTF8.self),
            process.terminationStatus
        )
    }
}
#endif
