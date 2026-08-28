#if os(Linux)
import Foundation
import Glibc

/// Thread-safe holder for the state the HTTP server serves. The refresh loop (MainActor) writes it;
/// the accept threads read it without hopping actors, so a slow refresh never blocks a request.
final class UsageStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var state = LocalUsageAPI.State(enabledOrderedIDs: [], knownIDs: [], snapshots: [:])

    func read() -> LocalUsageAPI.State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    func write(_ newValue: LocalUsageAPI.State) {
        lock.lock(); state = newValue; lock.unlock()
    }
}

/// POSIX-socket HTTP/1.1 listener — the Linux counterpart of the macOS `LocalUsageServer`, which uses
/// Network.framework's `NWListener` (unavailable here). Routing and JSON stay in `LocalUsageAPI`, so
/// both platforms serve a byte-identical wire format.
final class LinuxUsageServer: @unchecked Sendable {
    // Canonical values live on the public `OpenUsageLinuxDaemon` so they can be used as default
    // arguments there; this internal type mirrors them for its own defaults.
    static let defaultPort = OpenUsageLinuxDaemon.defaultPort
    static let defaultBindAddress = OpenUsageLinuxDaemon.defaultBindAddress
    private static let headLimit = 8192
    private static let maxConcurrent = 16
    /// Per-read/write socket timeout, plus absolute deadlines for reading the request head and for
    /// writing the response. Without all three, `maxConcurrent` clients that stall — never finishing a
    /// request, or reading one byte just inside every send timeout — would wedge the server permanently:
    /// every worker would sit in `recv`/`send` and everyone else would get 503 forever.
    private static let socketTimeout: TimeInterval = 10
    private static let headDeadline: TimeInterval = 15
    private static let responseDeadline: TimeInterval = 30
    /// Cookie the dashboard uses to keep authenticating after the initial `?token=` load.
    static let tokenCookieName = "openusage_token"

    private let box: UsageStateBox
    private let port: UInt16
    private let bindAddress: String
    /// When set, every request must present this token. Required for non-loopback binds.
    private let token: String?
    private let activeLock = NSLock()
    private var active = 0

    init(box: UsageStateBox, port: UInt16 = defaultPort, bindAddress: String = defaultBindAddress, token: String? = nil) {
        self.box = box
        self.port = port
        self.bindAddress = bindAddress
        self.token = token
    }

    /// True when only processes on this machine can reach the listener.
    var isLoopbackOnly: Bool { Self.isLoopback(bindAddress) }

    static func isLoopback(_ address: String) -> Bool {
        address == "localhost" || address.hasPrefix("127.")
    }

    /// True when the string is an IPv4 address this server can bind.
    static func isValidBindAddress(_ address: String) -> Bool {
        if address == "localhost" { return true }
        var parsed = in_addr()
        return inet_pton(AF_INET, address, &parsed) == 1
    }

    enum ServerError: Error, CustomStringConvertible {
        case badAddress(String)
        case socketFailed(Int32)
        case bindFailed(String, UInt16, Int32)
        case listenFailed(Int32)

        var description: String {
            switch self {
            case .badAddress(let address):
                "not a valid IPv4 bind address: \(address)"
            case .socketFailed(let code):
                "socket() failed (errno \(code))"
            case .bindFailed(let address, let port, let code):
                "bind(\(address):\(port)) failed (errno \(code)) — port already in use?"
            case .listenFailed(let code):
                "listen() failed (errno \(code))"
            }
        }
    }

    /// Binds and starts accepting on a background thread. Throws loudly when the address or port is
    /// unavailable so the daemon can report it, rather than silently disabling the feature.
    func start() throws {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let resolved = bindAddress == "localhost" ? "127.0.0.1" : bindAddress
        guard inet_pton(AF_INET, resolved, &addr.sin_addr) == 1 else {
            throw ServerError.badAddress(bindAddress)
        }

        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw ServerError.socketFailed(errno) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw ServerError.bindFailed(bindAddress, port, code)
        }
        guard listen(fd, 32) == 0 else {
            let code = errno
            close(fd)
            throw ServerError.listenFailed(code)
        }

        Thread.detachNewThread { [self] in acceptLoop(fd) }
    }

    private func acceptLoop(_ listenFD: Int32) {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else {
                if errno == EINTR { continue }
                break
            }
            Self.applyTimeouts(clientFD)

            activeLock.lock()
            let overloaded = active >= Self.maxConcurrent
            if !overloaded { active += 1 }
            activeLock.unlock()

            if overloaded {
                send(LocalUsageAPI.busy, to: clientFD, extraHeaders: [])
                close(clientFD)
                continue
            }
            DispatchQueue.global(qos: .utility).async { [self] in
                handle(clientFD)
                activeLock.lock(); active -= 1; activeLock.unlock()
            }
        }
        close(listenFD)
    }

    /// A stalled peer must never own a worker indefinitely.
    private static func applyTimeouts(_ fd: Int32) {
        var timeout = timeval(tv_sec: Int(socketTimeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        // Guards against a peer that trickles one byte just inside every socket timeout.
        let deadline = Date().addingTimeInterval(Self.headDeadline)

        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard Date() < deadline else { return }
            let read = recv(fd, &chunk, chunk.count, 0)
            guard read > 0 else { return }
            buffer.append(contentsOf: chunk[0..<read])
            if buffer.count >= Self.headLimit { return }
        }
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
        let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
        let (method, path) = Self.parseRequestLine(head)
        // Never log the query: `/?token=<secret>` is a supported way to open the dashboard, and the log
        // file long outlives the request.
        AppLog.debug(.localAPI, "\(method) \(Self.redactingQuery(path))")

        var extraHeaders: [String] = []
        if let token {
            switch Self.authorization(head: head, path: path, token: token) {
            case .rejected:
                AppLog.warn(.localAPI, "rejected unauthenticated \(method) \(Self.redactingQuery(path))")
                send(Self.unauthorized, to: fd, extraHeaders: [])
                return
            case .acceptedFromQuery:
                // Let the bundled dashboard keep authenticating on its own XHRs without editing the
                // shared HTML, which is byte-identical to the macOS app's copy.
                extraHeaders.append(
                    "Set-Cookie: \(Self.tokenCookieName)=\(token); Path=/; HttpOnly; SameSite=Strict"
                )
            case .accepted:
                break
            }
        }
        send(LocalUsageAPI.respond(method: method, path: path, state: box.read()), to: fd, extraHeaders: extraHeaders)
    }

    // MARK: - Authentication

    enum AuthOutcome: Equatable {
        case accepted
        case acceptedFromQuery
        case rejected
    }

    static let unauthorized = LocalUsageAPI.Response(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))

    /// Accepts `Authorization: Bearer <token>`, a `?token=` query parameter, or the cookie set after a
    /// query-authenticated dashboard load. Compared in constant time so a wrong token leaks no timing.
    static func authorization(head: String, path: String, token: String) -> AuthOutcome {
        let lines = head.components(separatedBy: "\r\n").dropFirst()

        for line in lines {
            let lowered = line.lowercased()
            if lowered.hasPrefix("authorization:") {
                let value = line.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces)
                if value.lowercased().hasPrefix("bearer "),
                   constantTimeEquals(String(value.dropFirst("bearer ".count)), token) {
                    return .accepted
                }
            }
            if lowered.hasPrefix("cookie:") {
                let value = line.dropFirst("cookie:".count)
                for pair in value.split(separator: ";") {
                    let parts = pair.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2,
                          parts[0].trimmingCharacters(in: .whitespaces) == tokenCookieName else { continue }
                    if constantTimeEquals(parts[1].trimmingCharacters(in: .whitespaces), token) {
                        return .accepted
                    }
                }
            }
        }

        if let query = path.split(separator: "?", maxSplits: 1).dropFirst().first {
            for pair in query.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, parts[0] == "token" else { continue }
                if constantTimeEquals(String(parts[1]), token) {
                    return .acceptedFromQuery
                }
            }
        }
        return .rejected
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    // MARK: - Request/response wire format

    /// Same tolerant parse as the macOS server: a malformed or empty head routes to 404, never traps.
    static func parseRequestLine(_ head: String) -> (method: String, path: String) {
        guard let requestLine = head.split(separator: "\r\n", maxSplits: 1).first else { return ("", "/") }
        let parts = requestLine.split(separator: " ")
        return (
            parts.indices.contains(0) ? String(parts[0]) : "",
            parts.indices.contains(1) ? String(parts[1]) : "/"
        )
    }

    /// Strips the query string so a token passed as `?token=…` never reaches the log file.
    static func redactingQuery(_ path: String) -> String {
        guard let markIndex = path.firstIndex(of: "?") else { return path }
        return path[..<markIndex] + "?<redacted>"
    }

    static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 503: "Service Unavailable"
        default: "OK"
        }
    }

    /// Builds the response head.
    ///
    /// No CORS headers are sent, on any bind. The macOS app sends `Access-Control-Allow-Origin: *`, but
    /// on a loopback API that is an open door: any website the user visits could read their usage from
    /// `http://127.0.0.1:6736`. The bundled dashboard is same-origin and needs no CORS, and non-browser
    /// clients (curl, scripts, native apps) are unaffected by its absence.
    static func responseHead(
        for response: LocalUsageAPI.Response,
        extraHeaders: [String] = []
    ) -> String {
        var head = "HTTP/1.1 \(response.status) \(reasonPhrase(for: response.status))\r\n"
        head += "Connection: close\r\n"
        for header in extraHeaders {
            head += header + "\r\n"
        }
        if let body = response.body {
            head += "Content-Type: \(response.contentType)\r\n"
            head += "Content-Length: \(body.count)\r\n\r\n"
        } else {
            head += "Content-Length: 0\r\n\r\n"
        }
        return head
    }

    private func send(_ response: LocalUsageAPI.Response, to fd: Int32, extraHeaders: [String]) {
        let head = Self.responseHead(for: response, extraHeaders: extraHeaders)
        let payload = Data(head.utf8) + (response.body ?? Data())

        let deadline = Date().addingTimeInterval(Self.responseDeadline)
        payload.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                // A peer that stops reading trips SO_SNDTIMEO; one that reads a trickle just inside
                // every timeout is caught by the absolute deadline. Either way the worker is released.
                guard Date() < deadline else {
                    AppLog.warn(.localAPI, "dropped a connection that stalled while reading the response")
                    return
                }
                let written = Glibc.send(fd, pointer, remaining, Int32(MSG_NOSIGNAL))
                guard written > 0 else { return }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }
}
#endif
