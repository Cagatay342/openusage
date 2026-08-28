import Foundation

/// Cross-platform well-known directory helpers for the headless core.
enum WellKnownPaths {
    /// User home directory (`%USERPROFILE%` on Windows, `~` elsewhere).
    static var home: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Roaming app data (`%APPDATA%` on Windows, `~/Library/Application Support` on macOS,
    /// `$XDG_DATA_HOME` on Linux).
    static var applicationSupport: URL {
        #if os(Windows)
        if let appData = ProcessInfo.processInfo.environment["APPDATA"], !appData.isEmpty {
            return URL(fileURLWithPath: appData, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #elseif os(Linux)
        return xdgDirectory("XDG_DATA_HOME", fallback: ".local/share")
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
    }

    /// Local app data (`%LOCALAPPDATA%` on Windows, `~/Library` on macOS, `$XDG_STATE_HOME` on Linux).
    static var localAppData: URL {
        #if os(Windows)
        if let localAppData = ProcessInfo.processInfo.environment["LOCALAPPDATA"], !localAppData.isEmpty {
            return URL(fileURLWithPath: localAppData, isDirectory: true)
        }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        #elseif os(Linux)
        // swift-corelibs-foundation returns an EMPTY array for `.libraryDirectory` on Linux, so the
        // macOS `[0]` subscript traps at launch. XDG's state dir is the correct home for logs here.
        return xdgDirectory("XDG_STATE_HOME", fallback: ".local/state")
        #else
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        #endif
    }

    #if os(Linux)
    /// XDG config dir (`$XDG_CONFIG_HOME`, default `~/.config`).
    static var configHome: URL {
        xdgDirectory("XDG_CONFIG_HOME", fallback: ".config")
    }
    #endif

    /// Cursor VS Code state DB (`state.vscdb`) under globalStorage.
    static var cursorStateDBPath: String {
        #if os(Windows)
        applicationSupport
            .appendingPathComponent("Cursor/User/globalStorage/state.vscdb", isDirectory: false)
            .path
        #elseif os(Linux)
        // Linux Cursor stores VS Code state under XDG config, not the data dir the other platforms use.
        configHome
            .appendingPathComponent("Cursor/User/globalStorage/state.vscdb", isDirectory: false)
            .path
        #else
        "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        #endif
    }

    /// Expand `~` and `~/…` to the current user's home directory.
    static func expandHome(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        if path == "~" { return home }
        return home + String(path.dropFirst())
    }

    #if os(Linux)
    /// Resolves an XDG base directory, honouring the environment variable when it holds an absolute
    /// path (the spec requires ignoring relative ones) and falling back to the spec's default.
    private static func xdgDirectory(_ variable: String, fallback: String) -> URL {
        if let value = ProcessInfo.processInfo.environment[variable], value.hasPrefix("/") {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(fallback, isDirectory: true)
    }
    #endif
}
