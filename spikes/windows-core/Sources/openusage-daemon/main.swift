import Foundation
#if os(Linux)
import OpenUsageCore

let usage = """
openusage-daemon — serve OpenUsage provider metrics over HTTP on this machine.

USAGE:
  openusage-daemon [--port <1-65535>] [--listen <ipv4>] [--interval <seconds>] [--token <secret>]

OPTIONS:
  --port <n>          TCP port to listen on (default: 6736)
  --listen <addr>     IPv4 address to bind (default: 127.0.0.1, loopback only).
                      Any address other than loopback requires a token.
  --interval <sec>    Seconds between provider refreshes (default: 300, minimum: 30)
  --token <secret>    Require this token on every request. Prefer the OPENUSAGE_TOKEN
                      environment variable: command-line arguments are visible to other
                      users of this machine through `ps` and /proc.
  -h, --help          Show this help

ENDPOINTS:
  /                   Bundled usage dashboard
  /v1/usage           All enabled providers as JSON
  /v1/usage/<id>      One provider

REMOTE ACCESS:
  Forwarding the loopback port over SSH exposes nothing and needs no token:
      ssh -N -L 6736:127.0.0.1:6736 <user>@<this-host>
"""

/// CLI arguments are a system boundary, so every value is validated and anything unrecognised exits
/// loudly rather than being silently ignored — a typo like `--intrval 30` must not start a daemon that
/// quietly uses the default.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

var port = OpenUsageLinuxDaemon.defaultPort
var bindAddress = OpenUsageLinuxDaemon.defaultBindAddress
var interval: TimeInterval = 300
var token = ProcessInfo.processInfo.environment["OPENUSAGE_TOKEN"]?.trimmingCharacters(in: .whitespaces)

let arguments = Array(CommandLine.arguments.dropFirst())
var seen: Set<String> = []
var index = arguments.startIndex

while index < arguments.endIndex {
    let flag = arguments[index]

    if flag == "-h" || flag == "--help" {
        guard index == arguments.startIndex, arguments.count == 1 else {
            fail("\(flag) takes no other arguments")
        }
        print(usage)
        exit(0)
    }
    guard flag.hasPrefix("--") else {
        fail("unexpected argument '\(flag)'")
    }
    guard seen.insert(flag).inserted else {
        fail("\(flag) given more than once")
    }
    guard arguments.indices.contains(index + 1) else {
        fail("\(flag) requires a value")
    }
    let value = arguments[index + 1]
    index += 2

    switch flag {
    case "--port":
        guard let parsed = UInt16(value), parsed > 0 else {
            fail("--port must be an integer in 1…65535, got '\(value)'")
        }
        port = parsed
    case "--listen":
        guard OpenUsageLinuxDaemon.isValidBindAddress(value) else {
            fail("--listen must be an IPv4 address, got '\(value)'")
        }
        bindAddress = value
    case "--interval":
        guard let parsed = TimeInterval(value), parsed.isFinite, parsed >= 30 else {
            fail("--interval must be a finite number of seconds ≥ 30, got '\(value)'")
        }
        interval = parsed
    case "--token":
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { fail("--token must not be empty") }
        token = trimmed
    default:
        fail("unknown option '\(flag)'")
    }
}

if token?.isEmpty == true { token = nil }

// Usage data is personal and the API returns it to anyone who can open the socket, so a routable bind
// without a token is refused outright rather than merely warned about.
if !OpenUsageLinuxDaemon.isLoopbackAddress(bindAddress), token == nil {
    fail("""
        --listen \(bindAddress) exposes this API beyond the local machine, so a token is required.
        Set OPENUSAGE_TOKEN (preferred) or pass --token <secret>.
        To view it remotely without exposing anything, forward the loopback port over SSH instead:
            ssh -N -L \(port):127.0.0.1:\(port) <user>@<this-host>
        """)
}

await OpenUsageLinuxDaemon.run(port: port, bindAddress: bindAddress, interval: interval, token: token)

#else

// The daemon is the Linux delivery vehicle; macOS ships the menu-bar app and Windows the sidecar.
// Keeping the target buildable everywhere means `swift build` stays green on every platform.
FileHandle.standardError.write(Data("openusage-daemon is only supported on Linux.\n".utf8))
exit(1)

#endif
