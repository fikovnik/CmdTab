import AppKit
import Carbon.HIToolbox

private let tapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(proxy: proxy, type: type, event: event)
}

final class HotkeyTap {
    private let switcher: Switcher
    private var machPort: CFMachPort?

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
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    fileprivate func handle(proxy: CGEventTapProxy,
                            type: CGEventType,
                            event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that ever takes too long. Just turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let machPort { CGEvent.tapEnable(tap: machPort, enable: true) }
            return nil
        }

        let command = event.flags.contains(.maskCommand)
        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .flagsChanged {
            // Releasing Cmd is what commits the selection.
            if switcher.isCycling && !command {
                switcher.commit()
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        if switcher.isCycling {
            if type == .keyDown {
                switch key {
                case kVK_Escape:
                    switcher.cancel()
                case kVK_Tab:
                    switcher.step(tabDirection)
                case kVK_ANSI_Grave:
                    switcher.step(-tabDirection)
                default:
                    break
                }
            }
            // Swallow everything while the switcher owns the keyboard, so the
            // frontmost app never sees half a chord.
            return nil
        }

        // Only plain Cmd (optionally with Shift) starts a cycle. Leave
        // Cmd+Ctrl+Tab / Cmd+Opt+Tab to whatever else is bound to them.
        let disallowed: CGEventFlags = [.maskControl, .maskAlternate]
        guard type == .keyDown, command, event.flags.isDisjoint(with: disallowed) else {
            return Unmanaged.passUnretained(event)
        }

        switch key {
        case kVK_Tab:
            switcher.start(.allWindows)
            return nil
        case kVK_ANSI_Grave:
            switcher.start(.currentApp)
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Tab moves forward in the all-windows cycle and backward in the
    /// single-app cycle, mirroring which key opened it.
    private var tabDirection: Int { switcher.mode == .currentApp ? -1 : 1 }
}
