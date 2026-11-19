import AppKit
import Combine
import SwiftUI

/// Owns the menu bar item and its popover. A popover (unlike SwiftUI's MenuBarExtra
/// window) resizes to fit its content in both directions, so no gap is left behind
/// when a stream ends.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    /// Created after the menu bar item so a Keychain prompt can't hold up the icon.
    private(set) var monitor: PlexMonitor!
    private var statusItem: NSStatusItem!
    let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    /// The dropdown closes once the mouse has been off it this long (set in the ⚙︎ menu).
    var autoCloseDelay: TimeInterval {
        #if DEBUG
        if let debugAutoCloseDelay { return debugAutoCloseDelay }
        #endif
        let saved = UserDefaults.standard.object(forKey: autoCloseKey) as? Int
        return TimeInterval(saved ?? defaultAutoCloseSeconds)
    }
    #if DEBUG
    var debugAutoCloseDelay: TimeInterval?
    #endif
    private var autoCloseTimer: Timer?
    private var outsideClickMonitor: Any?
    private var lastMouseInside = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        updateButton(count: 0)

        monitor = PlexMonitor()

        let host = NSHostingController(rootView: ContentView().environmentObject(monitor))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        monitor.$sessions
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] in self?.updateButton(count: $0) }
            .store(in: &cancellables)

        #if DEBUG
        DebugDemo.runIfRequested(self)
        #endif
    }

    /// Opening the app again (e.g. from Applications) shows the dropdown,
    /// which helps when the menu bar icon is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePopover() }
        return false
    }

    private func updateButton(count: Int) {
        guard let button = statusItem.button else { return }
        button.image = count > 0 ? MenuBarIcon.active : MenuBarIcon.idle
        button.title = count > 0 ? "\(count)" : ""
    }

    @objc func togglePopover() {
        guard let button = statusItem.button, popover.contentViewController != nil else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startAutoClose()
        }
    }

    // MARK: Auto-close

    private func startAutoClose() {
        // Clicks in other apps don't always reach a transient popover (the app may
        // not be active), so watch for them directly. Clicks on our own icon are
        // left to togglePopover.
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let onIcon = self.statusItem.button?.window?.frame.contains(NSEvent.mouseLocation) == true
                    if !onIcon { self.popover.performClose(nil) }
                }
            }
        }
        lastMouseInside = Date()
        autoCloseTimer?.invalidate()
        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMouse() }
        }
    }

    private func checkMouse() {
        let mouse = NSEvent.mouseLocation
        let frames = [popover.contentViewController?.view.window?.frame, statusItem.button?.window?.frame]
        let hasSheet = popover.contentViewController?.view.window?.attachedSheet != nil
        if hasSheet || frames.contains(where: { $0?.contains(mouse) == true }) {
            lastMouseInside = Date()
        } else if autoCloseDelay > 0, Date().timeIntervalSince(lastMouseInside) >= autoCloseDelay {
            popover.performClose(nil)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }
}

