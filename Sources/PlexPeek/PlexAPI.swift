import Foundation

// MARK: - Models

struct PlexServer: Identifiable, Hashable {
    let id: String          // clientIdentifier
    let name: String
    let accessToken: String
    let owned: Bool
    let connections: [Connection]

    struct Connection: Hashable {
        let uri: String
        let local: Bool
        let relay: Bool
    }
}

struct PlexSession: Identifiable, Hashable {
    let id: String
    let type: String                // movie, episode, track, ...
    let title: String
    let grandparentTitle: String?   // show / artist
    let parentTitle: String?        // season / album
    let seasonNumber: Int?
    let episodeNumber: Int?
    let year: Int?
    let posterPath: String?
    let duration: Int               // ms
    let viewOffset: Int             // ms
    let userName: String
    let userThumb: String?
    let playerName: String
    let playerProduct: String
    let platform: String
    let state: String               // playing, paused, buffering
    let isLocal: Bool
    let bandwidthKbps: Int?
    let resolution: String?
    let decision: String            // Direct Play / Direct Stream / Transcode
    let sessionID: String?          // Plex's Session.id, needed to stop the stream

    var headline: String {
        switch type {
        case "episode": return grandparentTitle ?? title
        case "track": return title
        default: return year.map { "\(title) (\($0))" } ?? title
        }
    }

    var subtitle: String? {
        switch type {
        case "episode":
            var prefix = ""
            if let s = seasonNumber, let e = episodeNumber {
                prefix = String(format: "S%02dE%02d · ", s, e)
            }
            return prefix + title
        case "track":
            return [grandparentTitle, parentTitle].compactMap { $0 }.joined(separator: " — ")
        default:
            return nil
        }
    }

    var progress: Double {
        duration > 0 ? min(1, Double(viewOffset) / Double(duration)) : 0
    }
}

enum PlexError: LocalizedError {
    case badResponse(Int)
    case noConnection
    case pinExpired

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "Plex returned HTTP \(code)"
        case .noConnection: return "Couldn't reach your Plex server"
        case .pinExpired: return "Sign-in timed out"
        }
    }
}

// MARK: - API

enum PlexAPI {
    static let product = "Plex Peek"

    static var clientID: String {
        if let id = UserDefaults.standard.string(forKey: "clientID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "clientID")
        return id
    }

    static func request(_ url: URL, token: String? = nil, method: String = "GET", timeout: TimeInterval = 10) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(product, forHTTPHeaderField: "X-Plex-Product")
        req.setValue(clientID, forHTTPHeaderField: "X-Plex-Client-Identifier")
        req.setValue("macOS", forHTTPHeaderField: "X-Plex-Platform")
        if let token { req.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
        return req
    }

    #if DEBUG
    /// Debug-only: simulates the network being down.
    nonisolated(unsafe) static var debugOffline = false
    #endif

    static func json(_ req: URLRequest) async throws -> Any {
        #if DEBUG
        if debugOffline { throw URLError(.notConnectedToInternet) }
        #endif
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PlexError.badResponse(http.statusCode)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: Sign-in (PIN flow — the user signs in on plex.tv in their browser)

    struct Pin { let id: Int; let code: String }

    static func createPin() async throws -> Pin {
        let url = URL(string: "https://plex.tv/api/v2/pins?strong=true")!
        let obj = try await json(request(url, method: "POST")) as? [String: Any] ?? [:]
        guard let id = obj.int("id"), let code = obj["code"] as? String else { throw PlexError.badResponse(0) }
        return Pin(id: id, code: code)
    }

    static func authURL(for pin: Pin) -> URL {
        var c = URLComponents(string: "https://app.plex.tv/auth")!
        var frag = URLComponents()
        frag.queryItems = [
            URLQueryItem(name: "clientID", value: clientID),
            URLQueryItem(name: "code", value: pin.code),
            URLQueryItem(name: "context[device][product]", value: product),
        ]
        c.fragment = "?" + (frag.percentEncodedQuery ?? "")
        return c.url!
    }

    /// Polls until the user finishes signing in on plex.tv. Gives up after ~5 minutes.
    static func waitForToken(pin: Pin) async throws -> String {
        let url = URL(string: "https://plex.tv/api/v2/pins/\(pin.id)")!
        for _ in 0..<150 {
            try await Task.sleep(for: .seconds(2))
            let obj = try await json(request(url)) as? [String: Any] ?? [:]
            if let token = obj["authToken"] as? String, !token.isEmpty { return token }
        }
        throw PlexError.pinExpired
    }

    // MARK: Servers

    static func servers(token: String) async throws -> [PlexServer] {
        let url = URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1")!
        let list = try await json(request(url, token: token)) as? [[String: Any]] ?? []
        return list.compactMap { r in
            guard (r["provides"] as? String ?? "").contains("server"),
                  let id = r["clientIdentifier"] as? String else { return nil }
            let conns = (r["connections"] as? [[String: Any]] ?? []).compactMap { c -> PlexServer.Connection? in
                guard let uri = c["uri"] as? String else { return nil }
                return .init(uri: uri, local: c["local"] as? Bool ?? false, relay: c["relay"] as? Bool ?? false)
            }
            return PlexServer(id: id,
                              name: r["name"] as? String ?? "Plex",
                              accessToken: r["accessToken"] as? String ?? token,
                              owned: r["owned"] as? Bool ?? false,
                              connections: conns)
        }
    }

    /// Tries local first, then remote, then Plex relay; returns the first base URL that answers.
    static func bestConnection(for server: PlexServer) async -> URL? {
        let ordered = server.connections.filter { $0.local && !$0.relay }
            + server.connections.filter { !$0.local && !$0.relay }
            + server.connections.filter { $0.relay }
        return await withTaskGroup(of: (Int, URL?).self) { group in
            for (i, conn) in ordered.enumerated() {
                group.addTask {
                    guard let base = URL(string: conn.uri) else { return (i, nil) }
                    let req = request(base.appending(path: "identity"), token: server.accessToken, timeout: 4)
                    guard let (_, resp) = try? await URLSession.shared.data(for: req),
                          (resp as? HTTPURLResponse)?.statusCode == 200 else { return (i, nil) }
                    return (i, base)
                }
            }
            var results: [Int: URL] = [:]
            for await (i, url) in group { if let url { results[i] = url } }
            return results.keys.min().flatMap { results[$0] }
        }
    }

    // MARK: Sessions

    static func sessions(base: URL, token: String) async throws -> [PlexSession] {
        let obj = try await json(request(base.appending(path: "status/sessions"), token: token)) as? [String: Any]
        let items = (obj?["MediaContainer"] as? [String: Any])?["Metadata"] as? [[String: Any]] ?? []
        return items.map(parseSession)
    }

    private static func parseSession(_ m: [String: Any]) -> PlexSession {
        let user = m["User"] as? [String: Any] ?? [:]
        let player = m["Player"] as? [String: Any] ?? [:]
        let session = m["Session"] as? [String: Any] ?? [:]
        let media = (m["Media"] as? [[String: Any]])?.first ?? [:]
        let transcode = m["TranscodeSession"] as? [String: Any]
        let type = m["type"] as? String ?? ""

        let decision: String
        if let t = transcode {
            let v = t["videoDecision"] as? String, a = t["audioDecision"] as? String
            decision = (v == "transcode" || a == "transcode") ? "Transcode" : "Direct Stream"
        } else {
            decision = "Direct Play"
        }

        var resolution = media["videoResolution"] as? String
        if let r = resolution, Int(r) != nil { resolution = r + "p" }
        if resolution?.lowercased() == "4k" { resolution = "4K" }

        let poster = type == "episode"
            ? (m["grandparentThumb"] as? String ?? m["thumb"] as? String)
            : (m["thumb"] as? String ?? m["parentThumb"] as? String)

        return PlexSession(
            id: session["id"] as? String ?? m.string("sessionKey") ?? UUID().uuidString,
            type: type,
            title: m["title"] as? String ?? "Unknown",
            grandparentTitle: m["grandparentTitle"] as? String,
            parentTitle: m["parentTitle"] as? String,
            seasonNumber: m.int("parentIndex"),
            episodeNumber: m.int("index"),
            year: m.int("year"),
            posterPath: poster,
            duration: m.int("duration") ?? 0,
            viewOffset: m.int("viewOffset") ?? 0,
            userName: user["title"] as? String ?? "Someone",
            userThumb: user["thumb"] as? String,
            playerName: player["title"] as? String ?? "",
            playerProduct: player["product"] as? String ?? "",
            platform: player["platform"] as? String ?? "",
            state: player["state"] as? String ?? "playing",
            isLocal: (session["location"] as? String).map { $0 == "lan" } ?? (player["local"] as? Bool ?? false),
            bandwidthKbps: session.int("bandwidth"),
            resolution: type == "track" ? nil : resolution,
            decision: decision,
            sessionID: session["id"] as? String
        )
    }

    /// Stops a stream and shows `reason` to the viewer. Requires Plex Pass and the server owner's token.
    static func terminate(base: URL, token: String, sessionID: String, reason: String) async throws {
        var c = URLComponents(url: base.appending(path: "status/sessions/terminate"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "sessionId", value: sessionID),
            URLQueryItem(name: "reason", value: reason),
        ]
        let (_, resp) = try await URLSession.shared.data(for: request(c.url!, token: token))
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PlexError.badResponse(http.statusCode)
        }
    }

    static func imageURL(base: URL, token: String, path: String, width: Int, height: Int) -> URL? {
        var c = URLComponents(url: base.appending(path: "photo/:/transcode"), resolvingAgainstBaseURL: false)
        c?.queryItems = [
            URLQueryItem(name: "width", value: "\(width)"),
            URLQueryItem(name: "height", value: "\(height)"),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "upscale", value: "1"),
            URLQueryItem(name: "url", value: path),
            URLQueryItem(name: "X-Plex-Token", value: token),
        ]
        return c?.url
    }

    static func notificationsURL(base: URL, token: String) -> URL? {
        var c = URLComponents(url: base.appending(path: ":/websockets/notifications"), resolvingAgainstBaseURL: false)
        c?.scheme = base.scheme == "https" ? "wss" : "ws"
        c?.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
        return c?.url
    }
}

// Plex JSON sometimes sends numbers as strings, so read them leniently.
extension Dictionary where Key == String, Value == Any {
    func int(_ key: String) -> Int? {
        if let i = self[key] as? Int { return i }
        if let s = self[key] as? String { return Int(s) }
        if let d = self[key] as? Double { return Int(d) }
        return nil
    }

    func string(_ key: String) -> String? {
        if let s = self[key] as? String { return s }
        if let i = self[key] as? Int { return String(i) }
        return nil
    }
}
