import AppKit
import Foundation
import Network
import ServiceManagement

/// Owns sign-in state, the chosen server, and the live list of sessions.
@MainActor
final class PlexMonitor: ObservableObject {
    enum Status: Equatable {
        case signedOut
        case signingIn
        case connecting
        case connected(remote: Bool)
        case error(String)
    }

    @Published private(set) var status: Status = .signedOut
    @Published private(set) var sessions: [PlexSession] = []
    @Published private(set) var servers: [PlexServer] = []
    @Published private(set) var server: PlexServer?
    @Published private(set) var baseURL: URL?
    @Published private(set) var lastUpdated: Date?
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet { updateLaunchAtLogin() }
    }

    private var userToken: String? = Keychain.get("userToken")
    private var pollTask: Task<Void, Never>?
    private var socketTask: URLSessionWebSocketTask?
    private var refreshDebounce: Task<Void, Never>?
    var retryDelay: Duration = .seconds(30)
    private var isConnecting = false
    private let pathMonitor = NWPathMonitor()
    private var networkWasDown = false

    var token: String? { server?.accessToken }
    var activeCount: Int { sessions.count }
    var totalBandwidthKbps: Int { sessions.compactMap(\.bandwidthKbps).reduce(0, +) }

    init() {
        watchNetworkAndSleep()
        if userToken != nil {
            Task { await connect() }
        }
    }

    // MARK: Sign in / out

    func signIn() {
        status = .signingIn
        Task {
            do {
                let pin = try await PlexAPI.createPin()
                NSWorkspace.shared.open(PlexAPI.authURL(for: pin))
                let token = try await PlexAPI.waitForToken(pin: pin)
                Keychain.set(token, for: "userToken")
                userToken = token
                await connect()
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    func signOut() {
        stop()
        Keychain.set(nil, for: "userToken")
        UserDefaults.standard.removeObject(forKey: "serverID")
        userToken = nil
        servers = []
        server = nil
        sessions = []
        status = .signedOut
    }

    func select(_ server: PlexServer) {
        UserDefaults.standard.set(server.id, forKey: "serverID")
        Task { await connect() }
    }

    // MARK: Connection

    func connect() async {
        guard let userToken else { status = .signedOut; return }
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        stop()
        status = .connecting
        do {
            servers = try await PlexAPI.servers(token: userToken)
            let savedID = UserDefaults.standard.string(forKey: "serverID")
            guard let chosen = servers.first(where: { $0.id == savedID })
                    ?? servers.first(where: \.owned)
                    ?? servers.first else {
                status = .error("No Plex servers found on this account")
                return
            }
            server = chosen
            guard let base = await PlexAPI.bestConnection(for: chosen) else {
                status = .error(PlexError.noConnection.localizedDescription)
                scheduleReconnect()
                return
            }
            baseURL = base
            let isLocal = chosen.connections.first { $0.uri == base.absoluteString }?.local ?? false
            status = .connected(remote: !isLocal)
            await refresh()
            startPolling()
            openSocket()
        } catch {
            #if DEBUG
            print("connect failed:", error is CancellationError ? "cancelled" : error.localizedDescription)
            #endif
            status = .error(error.localizedDescription)
            scheduleReconnect()
        }
    }

    func refresh() async {
        guard let baseURL, let token else { return }
        do {
            sessions = try await PlexAPI.sessions(base: baseURL, token: token)
                .sorted { $0.userName.localizedCaseInsensitiveCompare($1.userName) == .orderedAscending }
            lastUpdated = Date()
        } catch {
            // The address may have changed (e.g. left home Wi-Fi); find a new route.
            // Run outside the current (soon cancelled) poll task.
            Task { await self.connect() }
        }
    }

    /// Stops someone's stream. Returns an error message, or nil on success.
    func stopStream(_ session: PlexSession, message: String) async -> String? {
        guard let baseURL, let token, let sessionID = session.sessionID else {
            return "This stream can't be stopped from here."
        }
        do {
            try await PlexAPI.terminate(base: baseURL, token: token, sessionID: sessionID, reason: message)
            try? await Task.sleep(for: .seconds(1))
            await refresh()
            return nil
        } catch PlexError.badResponse(let code) where code == 401 || code == 403 {
            return "Plex refused (HTTP \(code)). Stopping streams needs Plex Pass and the server owner's account."
        } catch {
            return error.localizedDescription
        }
    }

    private func stop() {
        pollTask?.cancel()
        pollTask = nil
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
    }

    private func scheduleReconnect() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: self?.retryDelay ?? .seconds(30))
            guard !Task.isCancelled else { return }
            // connect() cancels pollTask (this task), so run it as its own task.
            Task { await self?.connect() }
        }
    }

    /// Reconnects as soon as the network comes back or the Mac wakes,
    /// rather than waiting for the next retry.
    private func watchNetworkAndSleep() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(up: up) }
        }
        pathMonitor.start(queue: .main)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconnectSoon() }
        }
    }

    private func networkChanged(up: Bool) {
        if !up {
            networkWasDown = true
        } else if networkWasDown {
            networkWasDown = false
            reconnectSoon()
        }
    }

    private func reconnectSoon() {
        guard userToken != nil else { return }
        Task {
            // Give Wi-Fi/DNS a moment to settle.
            try? await Task.sleep(for: .seconds(2))
            await connect()
        }
    }

    /// Keeps progress bars moving; faster while someone is watching.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = (self?.sessions.isEmpty ?? true) ? 30.0 : 10.0
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    // MARK: Live notifications

    /// Plex pushes play/pause/stop events over a websocket, so changes show up right away.
    private func openSocket() {
        guard let baseURL, let token, let url = PlexAPI.notificationsURL(base: baseURL, token: token) else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        socketTask = task
        task.resume()
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socketTask === task else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message, text.contains("PlaySessionStateNotification") {
                        self.debouncedRefresh()
                    }
                    self.receive(on: task)
                case .failure:
                    // Polling keeps working; try the socket again shortly.
                    self.socketTask = nil
                    try? await Task.sleep(for: .seconds(15))
                    if self.socketTask == nil, self.baseURL != nil { self.openSocket() }
                }
            }
        }
    }

    private func debouncedRefresh() {
        refreshDebounce?.cancel()
        refreshDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: Helpers

    func imageURL(_ path: String?, width: Int, height: Int) -> URL? {
        guard let path, let baseURL, let token else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }  // plex.tv avatars
        return PlexAPI.imageURL(base: baseURL, token: token, path: path, width: width, height: height)
    }

    func openPlexWeb() {
        NSWorkspace.shared.open(URL(string: "https://app.plex.tv/desktop")!)
    }

    #if DEBUG
    /// Lets the debug demo drive the UI with fake sessions.
    func setDemoToken(_ token: String) { userToken = token }

    func setDemoSessions(_ demo: [PlexSession]) {
        stop()
        status = .connected(remote: false)
        sessions = demo
        lastUpdated = Date()
    }
    #endif

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
