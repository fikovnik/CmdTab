import AppKit
import Carbon.HIToolbox

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()

    // Decode here, before hopping to the main actor: the switcher only needs the
    // key and the modifiers, and CGEvent is not Sendable, so keeping it on this
    // side of the boundary is what lets the hop be checked rather than excused.
    let flags = event.flags
    let key = Int(event.getIntegerValueField(.keyboardEventKeycode))

    // `start` installs the run loop source on the main run loop, so this
    // callback is always delivered on the main thread.
    var verdict = HotkeyTap.Verdict.pass
    MainActor.assumeIsolated { verdict = tap.handle(type: type, flags: flags, key: key) }

    return verdict == .swallow ? nil : Unmanaged.passUnretained(event)
}

@MainActor
final class HotkeyTap {
    /// What the tap should do with an event once the switcher has seen it.
    enum Verdict: Sendable {
        /// Hand the event on to the frontmost app.
        case pass
        /// Drop it, so the app never sees half a chord.
        case swallow
    }

    private let switcher: Switcher
    private var machPort: CFMachPort?
    private var source: CFRunLoopSource?

    init(switcher: Switcher) {
        self.switcher = switcher
    }

    @discardableResult
    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        machPort = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    /// Tear the tap down. `start` hands the tap an *unretained* pointer to
    /// `self`, so the tap must never outlive this object.
    func stop() {
        guard let machPort else { return }
        CGEvent.tapEnable(tap: machPort, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(machPort)
        self.source = nil
        self.machPort = nil
    }

    fileprivate func handle(type: CGEventType, flags: CGEventFlags, key: Int) -> Verdict {
        // The system disables a tap that ever takes too long. Just turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Diagnostics.note("tap disabled (type \(type.rawValue)), re-enabling")
            if let machPort { CGEvent.tapEnable(tap: machPort, enable: true) }
            return .swallow
        }

        let command = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)

        if type == .flagsChanged {
            // Releasing Cmd is what commits the selection.
            if switcher.isCycling && !command {
                switcher.commit()
            }
            return .pass
        }

        guard type == .keyDown || type == .keyUp else { return .pass }

        // A key arriving without Cmd while cycling means the release that should
        // have ended the cycle never got here. The system drops events for as
        // long as it has the tap disabled. Commit what was selected and let the
        // key through, rather than swallowing the keyboard until the next Cmd.
        if switcher.isCycling && !command {
            Diagnostics.note("missed Cmd release, recovering")
            switcher.commit()
            return .pass
        }

        if switcher.isCycling {
            if type == .keyDown {
                switch key {
                case kVK_Escape, kVK_ANSI_Period:
                    switcher.cancel()
                case kVK_Return, kVK_ANSI_KeypadEnter:
                    switcher.commit()
                case kVK_RightArrow:
                    switcher.toggleScope()
                case kVK_DownArrow:
                    switcher.step(1)
                case kVK_UpArrow:
                    switcher.step(-1)
                case kVK_PageDown:
                    switcher.step(switcher.pageSize, wrap: false)
                case kVK_PageUp:
                    switcher.step(-switcher.pageSize, wrap: false)
                case kVK_Tab:
                    switcher.step(shift ? -tabDirection : tabDirection)
                case kVK_ANSI_Grave:
                    switcher.step(shift ? tabDirection : -tabDirection)
                default:
                    break
                }
            }
            // Swallow everything while the switcher owns the keyboard.
            return .swallow
        }

        // Only plain Cmd (optionally with Shift, which reverses) starts a cycle.
        // Leave Cmd+Ctrl+Tab / Cmd+Opt+Tab to whatever else is bound to them.
        let disallowed: CGEventFlags = [.maskControl, .maskAlternate]
        guard type == .keyDown, command, flags.isDisjoint(with: disallowed) else {
            return .pass
        }

        switch key {
        case kVK_Tab:
            switcher.start(.allWindows, reversed: shift)
            return .swallow
        case kVK_ANSI_Grave:
            switcher.start(.currentApp, reversed: shift)
            return .swallow
        default:
            return .pass
        }
    }

    /// Tab moves forward in the all-windows cycle and backward in the
    /// single-app cycle, mirroring which key opened it. Shift reverses both.
    private var tabDirection: Int { switcher.mode == .currentApp ? -1 : 1 }
}
