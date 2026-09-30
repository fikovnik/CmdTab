import AppKit
import Carbon.HIToolbox
import CmdTabConfig

#if DIAGNOSTICS
/// Milliseconds per tick of `mach_absolute_time`, which is the clock
/// `CGEvent.timestamp` is stamped from.
private let millisecondsPerTick: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom) / 1_000_000
}()
#endif

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()

    // Decode here, before hopping to the main actor: the switcher only needs the
    // key and the modifiers, and CGEvent is not Sendable, so keeping it on this
    // side of the boundary is what lets the hop be checked rather than excused.
    let flags = event.flags
    let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
    #if DIAGNOSTICS
    // How long this event sat in the queue before the main thread got to it.
    // The tap, the reveal timer and the window scan all share that thread, so a
    // late event is also a HUD that could not have appeared on time.
    let lateness = Double(mach_absolute_time() &- event.timestamp) * millisecondsPerTick
    #endif

    // `start` installs the run loop source on the main run loop, so this
    // callback is always delivered on the main thread.
    var verdict = HotkeyTap.Verdict.pass
    MainActor.assumeIsolated {
        #if DIAGNOSTICS
        if lateness > 50 {
            Diagnostics.note(String(format: "event type=%d key=%d delivered %.0f ms late",
                                    type.rawValue, key, lateness))
        }
        #endif
        verdict = tap.handle(type: type, flags: flags, key: key)
    }

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
    private let host: any WindowActions
    private var machPort: CFMachPort?
    private var source: CFRunLoopSource?

    /// What the config bound. Replaced wholesale on reload.
    var bindings = Bindings()

    /// The modifiers of the trigger that opened the current cycle. Releasing
    /// any of them is what commits. That used to be hardcoded to Cmd, and is
    /// now whatever the trigger names.
    private var activeHold: Chord.Modifiers?

    init(switcher: Switcher, host: any WindowActions) {
        self.switcher = switcher
        self.host = host
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

        let held = HotkeyTap.modifiers(flags)
        let shift = held.contains(.shift)

        if type == .flagsChanged {
            // Releasing the trigger's modifiers is what commits the selection.
            if switcher.isCycling, !stillHeld(held) { endCycle() }
            return .pass
        }

        guard type == .keyDown || type == .keyUp else { return .pass }

        // A key arriving without the trigger held while cycling means the
        // release that should have ended the cycle never got here. The system
        // drops events for as long as it has the tap disabled. Commit what was
        // selected and let the key through, rather than swallowing the keyboard
        // until the next trigger.
        if switcher.isCycling, !stillHeld(held) {
            Diagnostics.note("missed trigger release, recovering")
            endCycle()
            return .pass
        }

        if switcher.isCycling {
            if type == .keyDown { cycle(key: key, shift: shift) }
            // Swallow everything while the switcher owns the keyboard.
            return .swallow
        }

        guard type == .keyDown else { return .pass }

        let chord = Chord(keyCode: UInt16(key), modifiers: held)

        // Shift is not part of a switcher trigger. It reverses direction, so
        // try the chord as typed, then again without Shift.
        if let mode = bindings.switchers[chord] {
            begin(mode, trigger: chord, reversed: false)
            return .swallow
        }
        if shift {
            let unshifted = chord.removing(.shift)
            if let mode = bindings.switchers[unshifted] {
                begin(mode, trigger: unshifted, reversed: true)
                return .swallow
            }
        }

        // Any one-shot binding: tiling, a desktop switch, shell, AppleScript.
        // Swallowed so the chord does not reach the focused app as well. A
        // chord the config did not bind falls through untouched.
        if let command = bindings.locals[chord] {
            command.run(on: host)
            return .swallow
        }
        return .pass
    }

    private func begin(_ mode: SwitchMode, trigger: Chord, reversed: Bool) {
        activeHold = trigger.modifiers
        HUDPanel.modifierHint = trigger.modifierDisplay
        switcher.start(mode, reversed: reversed)
    }

    private func endCycle() {
        switcher.commit()
        activeHold = nil
    }

    /// Whether every modifier the trigger named is still down.
    private func stillHeld(_ held: Chord.Modifiers) -> Bool {
        guard let activeHold else { return false }
        return held.isSuperset(of: activeHold)
    }

    private func cycle(key: Int, shift: Bool) {
        switch key {
        case kVK_Escape, kVK_ANSI_Period:
            switcher.cancel()
            activeHold = nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            endCycle()
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
        default:
            // The trigger that opened this cycle steps forward. The other one
            // steps back. That is what makes Cmd+` walk the all-windows list
            // in reverse, and it now follows from the bindings rather than
            // from a hardcoded pair of key codes.
            guard let mode = bindings.switchers.first(where: { $0.key.keyCode == UInt16(key) })?.value
            else { break }
            let direction = mode == switcher.mode ? 1 : -1
            switcher.step(shift ? -direction : direction)
        }
    }

    /// Only the modifiers a tap can match on. `fn` is absent by construction:
    /// arrow and function keys set it implicitly, so matching on it would be
    /// wrong either way. See `Chord.Modifiers.tapMatchable`.
    private static func modifiers(_ flags: CGEventFlags) -> Chord.Modifiers {
        var m = Chord.Modifiers()
        if flags.contains(.maskShift) { m.insert(.shift) }
        if flags.contains(.maskControl) { m.insert(.control) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskCommand) { m.insert(.command) }
        return m
    }
}
