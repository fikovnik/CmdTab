import AppKit
import ApplicationServices

/// Tells the preview cache when a window's contents have changed.
///
/// Nothing in `NSWorkspace` reports a Chrome tab switch (same app, same
/// window, same Space), so a warmed frame kept whatever tab was open when the
/// Space was last refreshed. The row's title comes from AX and is current, so
/// title and preview disagreed, which is worse than a missing preview.
///
/// AX does report it: `AXTitleChanged` on an `AXWindow` element, measured
/// arriving 10 ms after the switch. Registered on the application element, so
/// one observer per app covers every window it will ever open.
@MainActor
enum AXWatcher {
    /// Start watching any app not watched yet, and drop the ones that exited.
    static func sync() {
        var live = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            live.insert(app.processIdentifier)
        }
        live.remove(ProcessInfo.processInfo.processIdentifier)

        for pid in observers.keys where !live.contains(pid) {
            observers[pid] = nil
        }
        for pid in live where observers[pid] == nil {
            observers[pid] = observe(pid)
        }
    }

    private static func observe(_ pid: pid_t) -> AXObserver? {
        var observer: AXObserver?
        guard AXObserverCreate(pid, axWatcherCallback, &observer) == .success,
              let observer else { return nil }

        let app = AXUIElementCreateApplication(pid)
        // A focus change is the other way a window's contents can go stale
        // without a workspace notification: the app redraws the newly keyed
        // window and dims the one it left.
        //
        // Those last two are also the only report macOS makes of a window
        // opening or being switched to *inside the app you are already in*.
        // `NSWorkspace` stays silent, because the frontmost app never changed.
        for name in [kAXTitleChangedNotification,
                     kAXFocusedWindowChangedNotification,
                     kAXWindowCreatedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, nil)
        }
        // .common, so it delivers while the event tap is pumping its own run
        // loop source.
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
        return observer
    }

    fileprivate static func contentsChanged(_ id: CGWindowID) {
        WindowPreview.shared.recapture(id)
    }

    /// A window of the app you are in became the focused one.
    ///
    /// The registry otherwise learns use only from `didActivateApplication`,
    /// which never fires for two windows of the *same* app, and with twenty
    /// Chrome windows open that is most switches. Without this the window you
    /// just used carries no stamp at all, so it ranks below every window that
    /// has one instead of one step away.
    fileprivate static func windowFocused(_ id: CGWindowID, pid: pid_t) {
        // A background app re-keying one of its own windows is not a switch.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        WindowRegistry.shared.promote(id)
    }

    /// An app opened a window. Equally unreported by `NSWorkspace`, and the
    /// consequence outlives the moment: a window never walked by the
    /// Accessibility API while it was on the active Space can never be walked
    /// afterwards, so it keeps no element and no title for the rest of the
    /// session, and focusing it falls to the WindowServer route.
    ///
    /// A brand new window has no CGWindowID yet, so this asks for a rescan
    /// rather than trying to learn the one element. The refresh is coalesced
    /// and by the time it runs the window is real.
    fileprivate static func windowCreated() {
        WindowRegistry.shared.scheduleRefresh()
    }
}

/// Held apart from the enum so the C callback can reach it without capturing.
@MainActor private var observers: [pid_t: AXObserver] = [:]

/// A C function rather than a closure: the Swift 6 region analyser crashes on a
/// closure of this signature converted to `AXObserverCallback`.
private func axWatcherCallback(_ observer: AXObserver, _ element: AXUIElement,
                               _ name: CFString, _ context: UnsafeMutableRawPointer?) {
    let notification = name as String

    // The observer's run loop source is on the main thread, so these hops are
    // already on the main actor. The callback signature just cannot say so.
    if notification == kAXWindowCreatedNotification as String {
        MainActor.assumeIsolated { AXWatcher.windowCreated() }
        return
    }

    // Chrome reports a title change for cells, buttons and text fields too,
    // several per keystroke in the address bar, and they all resolve to the
    // same window id. Only the window element means the window changed.
    var role: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
          (role as? String) == kAXWindowRole as String
    else { return }

    var id: CGWindowID = 0
    guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return }

    // Read the pid here rather than passing the element across: AXUIElement is
    // not Sendable, and the hop below is checked.
    var pid: pid_t = 0
    let focused = notification == kAXFocusedWindowChangedNotification as String
    if focused, AXUIElementGetPid(element, &pid) != .success { return }

    MainActor.assumeIsolated {
        AXWatcher.contentsChanged(id)
        if focused { AXWatcher.windowFocused(id, pid: pid) }
    }
}
