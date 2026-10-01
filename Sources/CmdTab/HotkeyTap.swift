import AppKit
import Carbon.HIToolbox
import CmdTabConfig

#if DIAGNOSTICS
/// Milliseconds per tick of `mach_absolute_time`, the clock of
/// `CGEvent.timestamp`.
private let millisecondsPerTick: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom) / 1_000_000
}()
#endif

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()

    // Read the key and the modifiers before the main actor hop. `CGEvent` is
    // not `Sendable`, and the switcher needs only these two values.
    let flags = event.flags
    let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
    #if DIAGNOSTICS
    // The time that the event waited before the main thread got it. The tap,
    // the reveal timer and the window scan use the same thread. Thus, a late
    // event also means a late HUD.
    //
    // A timestamp can be a few ticks later than `mach_absolute_time`. Thus,
    // the difference is signed, with a minimum of zero.
    let ticks = Int64(bitPattern: mach_absolute_time() &- event.timestamp)
    let lateness = ticks > 0 ? Double(ticks) * millisecondsPerTick : 0
    #endif

    // `start` adds the run loop source to the main run loop. Thus, this
    // callback always runs on the main thread.
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
    /// What the tap does with an event after `handle`.
    enum Verdict: Sendable {
        /// Send the event to the front app.
        case pass
        /// Discard the event, so that the app does not get a part of a chord.
        case swallow
    }

    private let switcher: Switcher
    private let host: any WindowActions
    private var machPort: CFMachPort?
    private var source: CFRunLoopSource?

    /// The chords from the config. A reload replaces the full value.
    var bindings = Bindings()

    /// The modifiers of the trigger that started the current cycle. When the
    /// user releases one of them, the switcher commits.
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

    /// Stops the tap. `start` gives the tap an unretained pointer to `self`.
    /// Thus, the tap must not live longer than this object.
    func stop() {
        guard let machPort else { return }
        CGEvent.tapEnable(tap: machPort, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(machPort)
        self.source = nil
        self.machPort = nil
    }

    fileprivate func handle(type: CGEventType, flags: CGEventFlags, key: Int) -> Verdict {
        // The system disables a tap that is too slow, and also on some user
        // input. Enable the tap again.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Diagnostics.note("tap disabled (type \(type.rawValue)), re-enabling")
            if let machPort { CGEvent.tapEnable(tap: machPort, enable: true) }
            return .swallow
        }

        let held = HotkeyTap.modifiers(flags)
        let shift = held.contains(.shift)

        if type == .flagsChanged {
            if switcher.isCycling, !stillHeld(held) { endCycle() }
            return .pass
        }

        guard type == .keyDown || type == .keyUp else { return .pass }

        // A key without the trigger modifiers during a cycle means that the
        // tap did not get the release. The system discards events while the
        // tap is disabled. Commit the selection and pass the key. Else the
        // tap discards all keys until the next trigger.
        if switcher.isCycling, !stillHeld(held) {
            Diagnostics.note("missed trigger release, recovering")
            endCycle()
            return .pass
        }

        if switcher.isCycling {
            if type == .keyDown { cycle(key: key, shift: shift) }
            // During a cycle, the front app gets no key events.
            return .swallow
        }

        guard type == .keyDown else { return .pass }

        let chord = Chord(keyCode: UInt16(key), modifiers: held)

        // Shift is not part of a switcher trigger. Shift reverses the
        // direction. Thus, find the chord as typed, then without Shift.
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

        // A binding with one action, for example a tile or a shell command.
        // Discard the chord, so that the focused app does not also get it.
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
            // The trigger key of this cycle steps forward. The trigger key of
            // the other mode steps back. For example, Cmd+` moves back in the
            // all-windows list.
            guard let mode = bindings.switchers.first(where: { $0.key.keyCode == UInt16(key) })?.value
            else { break }
            let direction = mode == switcher.mode ? 1 : -1
            switcher.step(shift ? -direction : direction)
        }
    }

    /// Only the modifiers that a chord can use. The arrow keys and the
    /// function keys set `fn` automatically. Thus, `fn` is not a modifier
    /// here. See `Chord.Modifiers.tapMatchable`.
    private static func modifiers(_ flags: CGEventFlags) -> Chord.Modifiers {
        var m = Chord.Modifiers()
        if flags.contains(.maskShift) { m.insert(.shift) }
        if flags.contains(.maskControl) { m.insert(.control) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskCommand) { m.insert(.command) }
        return m
    }
}
