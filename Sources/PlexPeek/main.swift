import AppKit

// Plain AppKit entry point: a SwiftUI App would need a scene, and its empty
// Settings window was popping up blank on launch.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    // The app only holds its delegate weakly; keep ours alive for the app's lifetime.
    withExtendedLifetime(delegate) {
        NSApplication.shared.run()
    }
}
