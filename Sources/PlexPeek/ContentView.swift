import SwiftUI

struct ContentView: View {
    @EnvironmentObject var monitor: PlexMonitor
    @AppStorage(autoCloseKey) private var autoCloseSeconds = defaultAutoCloseSeconds
    @State private var stopTarget: PlexSession?
    @State private var stopMessage = defaultStopMessage
    @State private var stopError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity)
            Divider()
            footer
        }
        .frame(width: 380)
        .alert(
            "Stop \(stopTarget?.userName ?? "this")'s stream?",
            isPresented: Binding(get: { stopTarget != nil }, set: { if !$0 { stopTarget = nil } }),
            presenting: stopTarget
        ) { session in
            TextField("Message to viewer", text: $stopMessage)
            Button("Stop Stream", role: .destructive) {
                Task { stopError = await monitor.stopStream(session, message: stopMessage) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("\(session.headline) will stop playing. They'll see the message below.")
        }
        .alert(
            "Couldn't stop the stream",
            isPresented: Binding(get: { stopError != nil }, set: { if !$0 { stopError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(stopError ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(monitor.server?.name ?? "Plex Peek").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if case .connected = monitor.status {
                Button {
                    Task { await monitor.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            settingsMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var settingsMenu: some View {
        Menu {
            if monitor.servers.count > 1 {
                Picker("Server", selection: Binding(
                    get: { monitor.server },
                    set: { if let s = $0 { monitor.select(s) } }
                )) {
                    ForEach(monitor.servers) { Text($0.name).tag(Optional($0)) }
                }
                Divider()
            }
            Picker("Auto-close", selection: $autoCloseSeconds) {
                Text("5 seconds").tag(5)
                Text("10 seconds").tag(10)
                Text("30 seconds").tag(30)
                Text("1 minute").tag(60)
                Text("Never").tag(0)
            }
            Toggle("Launch at Login", isOn: $monitor.launchAtLogin)
            Button("Open Plex Web") { monitor.openPlexWeb() }
            if monitor.status != .signedOut {
                Button("Sign Out") { monitor.signOut() }
            }
            Divider()
            Button("About Plex Peek \(appVersion)") {
                NSApp.activate()
                NSApp.orderFrontStandardAboutPanel(nil)
            }
            Button("Quit Plex Peek") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var statusColor: Color {
        switch monitor.status {
        case .connected: return .green
        case .connecting, .signingIn: return .yellow
        case .error: return .red
        case .signedOut: return .gray
        }
    }

    private var statusText: String {
        switch monitor.status {
        case .signedOut: return "Not signed in"
        case .signingIn: return "Waiting for Plex sign-in…"
        case .connecting: return "Connecting…"
        case .connected(let remote):
            let n = monitor.activeCount
            let streams = n == 0 ? "Idle" : "\(n) stream\(n == 1 ? "" : "s")"
            return "\(streams) · \(remote ? "Remote" : "Local")"
        case .error(let message): return message
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch monitor.status {
        case .signedOut, .signingIn:
            VStack(spacing: 10) {
                Image(systemName: "play.tv").font(.system(size: 34)).foregroundStyle(.secondary)
                Text("Sign in with your Plex account to see who's watching.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if monitor.status == .signingIn {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Sign in with Plex") { monitor.signIn() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)

        case .connecting:
            ProgressView().padding(30)

        case .error:
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(.orange)
                Button("Try Again") { Task { await monitor.connect() } }
            }
            .padding(24)

        case .connected:
            if monitor.sessions.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "moon.zzz").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Nobody's watching right now").foregroundStyle(.secondary)
                }
                .padding(28)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(monitor.sessions) { session in
                            SessionRow(session: session) {
                                stopMessage = defaultStopMessage
                                stopTarget = session
                            }
                            if session.id != monitor.sessions.last?.id { Divider().padding(.leading, 76) }
                        }
                    }
                }
                .frame(maxHeight: 460)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if monitor.totalBandwidthKbps > 0 {
                Label(formatBandwidth(monitor.totalBandwidthKbps), systemImage: "arrow.up.arrow.down")
            }
            Spacer()
            if let updated = monitor.lastUpdated {
                Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

// MARK: - Session row

struct SessionRow: View {
    @EnvironmentObject var monitor: PlexMonitor
    let session: PlexSession
    var onStop: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            poster

            VStack(alignment: .leading, spacing: 4) {
                Text(session.headline).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .padding(.trailing, 22)
                if let subtitle = session.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }

                HStack(spacing: 5) {
                    avatar
                    Text(session.userName).font(.caption.weight(.medium))
                    Text("·").foregroundStyle(.tertiary)
                    Text(deviceText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }

                HStack(spacing: 6) {
                    Image(systemName: stateIcon)
                        .font(.system(size: 9))
                        .foregroundStyle(session.state == "playing" ? Color.accentColor : .secondary)
                    ProgressView(value: session.progress)
                        .progressViewStyle(.linear)
                        .tint(session.state == "playing" ? .accentColor : .gray)
                    Text(remainingText).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Badge(text: session.decision, color: session.decision == "Transcode" ? .orange : .green)
                    if let res = session.resolution { Badge(text: res, color: .secondary) }
                    Badge(text: session.isLocal ? "LAN" : "WAN", color: .secondary)
                    if let bw = session.bandwidthKbps, bw > 0 {
                        Badge(text: formatBandwidth(bw), color: .secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .topTrailing) {
            if session.sessionID != nil {
                Button(action: onStop) {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Stop this stream")
                .padding(.top, 9)
                .padding(.trailing, 12)
            }
        }
    }

    private var poster: some View {
        let isTrack = session.type == "track"
        let size = isTrack ? CGSize(width: 50, height: 50) : CGSize(width: 50, height: 75)
        return AsyncImage(url: monitor.imageURL(session.posterPath, width: 100, height: Int(size.height * 2))) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle().fill(.quaternary)
                .overlay(Image(systemName: isTrack ? "music.note" : "film").foregroundStyle(.secondary))
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var avatar: some View {
        AsyncImage(url: monitor.imageURL(session.userThumb, width: 32, height: 32)) { image in
            image.resizable()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
        }
        .frame(width: 14, height: 14)
        .clipShape(Circle())
    }

    private var deviceText: String {
        [session.playerName, session.playerProduct]
            .filter { !$0.isEmpty }
            .first ?? session.platform
    }

    private var stateIcon: String {
        switch session.state {
        case "paused": return "pause.fill"
        case "buffering": return "hourglass"
        default: return "play.fill"
        }
    }

    private var remainingText: String {
        let left = max(0, session.duration - session.viewOffset) / 1000
        let h = left / 3600, m = (left % 3600) / 60
        return h > 0 ? "\(h)h \(m)m left" : "\(m)m left"
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(color == .secondary ? Color.secondary : color)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill((color == .secondary ? Color.secondary : color).opacity(0.15))
            )
    }
}

/// Seconds the mouse can be off the dropdown before it closes; 0 means never.
let autoCloseKey = "autoCloseSeconds"
let defaultAutoCloseSeconds = 10

let defaultStopMessage = "The server owner has stopped this stream."

let appVersion = "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")

func formatBandwidth(_ kbps: Int) -> String {
    kbps >= 1000 ? String(format: "%.1f Mbps", Double(kbps) / 1000) : "\(kbps) kbps"
}
