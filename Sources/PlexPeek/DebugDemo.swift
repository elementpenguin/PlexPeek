#if DEBUG
import AppKit

/// Debug-only: run with PLEXPEEK_DEMO=1 to open the popover and step through
/// fake stream counts, printing the popover height after each step.
@MainActor
enum DebugDemo {
    static func runIfRequested(_ app: AppDelegate) {
        guard let mode = ProcessInfo.processInfo.environment["PLEXPEEK_DEMO"] else { return }
        if mode == "reconnect" { return runReconnectTest(app) }
        if mode == "idle" { return }
        if mode == "autoclose" { return runAutoCloseTest(app) }
        if mode.hasPrefix("snapshot:") { return runSnapshot(app, to: String(mode.dropFirst(9))) }
        Task { @MainActor in
            app.monitor.setDemoSessions([])
            try? await Task.sleep(for: .seconds(1))
            app.togglePopover()
            for count in [0, 3, 1, 0, 2] {
                app.monitor.setDemoSessions((0..<count).map(fakeSession))
                try? await Task.sleep(for: .seconds(1))
                let h = app.popover.contentViewController?.view.window?.frame.height ?? -1
                print("streams=\(count) popoverHeight=\(Int(h))")
            }
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    /// Fakes an outage, then restores the network and checks that the automatic
    /// retry really reaches plex.tv (a bogus token should come back as HTTP 401).
    private static func runReconnectTest(_ app: AppDelegate) {
        Task { @MainActor in
            let m = app.monitor!
            m.retryDelay = .seconds(2)
            m.setDemoToken("bogus-token")
            PlexAPI.debugOffline = true
            print("-- network down")
            await m.connect()
            try? await Task.sleep(for: .seconds(1))
            print("-- network back")
            PlexAPI.debugOffline = false
            try? await Task.sleep(for: .seconds(9))
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    /// Opens the dropdown with a short auto-close delay and reports when it closes.
    private static func runAutoCloseTest(_ app: AppDelegate) {
        Task { @MainActor in
            app.debugAutoCloseDelay = 3
            app.monitor.setDemoSessions([])
            try? await Task.sleep(for: .seconds(1))
            app.togglePopover()
            for second in 1...6 {
                try? await Task.sleep(for: .seconds(1))
                print("t=\(second)s shown=\(app.popover.isShown)")
            }
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    /// Saves a PNG of the dropdown showing two fake streams.
    private static func runSnapshot(_ app: AppDelegate, to path: String) {
        Task { @MainActor in
            app.monitor.setDemoSessions((0..<2).map(fakeSession))
            try? await Task.sleep(for: .seconds(1))
            app.togglePopover()
            try? await Task.sleep(for: .seconds(1))
            if let view = app.popover.contentViewController?.view,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    private static func fakeSession(_ i: Int) -> PlexSession {
        PlexSession(id: "demo\(i)", type: "episode", title: "Episode \(i + 1)", grandparentTitle: "Demo Show",
                    parentTitle: nil, seasonNumber: 1, episodeNumber: i + 1, year: nil, posterPath: nil,
                    duration: 2_700_000, viewOffset: 900_000, userName: "User \(i + 1)", userThumb: nil,
                    playerName: "Apple TV", playerProduct: "Plex", platform: "tvOS", state: "playing",
                    isLocal: true, bandwidthKbps: 8000, resolution: "1080p", decision: "Direct Play",
                    sessionID: "demo\(i)")
    }
}
#endif
