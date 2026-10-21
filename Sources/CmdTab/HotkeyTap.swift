import AppKit
import CmdTabConfig

/// CGEvent timestamps use nanoseconds. Mach clock ticks require this conversion.
private let nanosecondsPerTick: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom)
}()

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
    let flags = event.flags
    let key = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
    let text = type == .keyDown ? NSEvent(cgEvent: event)?.charactersIgnoringModifiers : nil
    let timestamp = event.timestamp
    var consume = false
    // The tap source runs on the main run loop.
    MainActor.assumeIsolated {
        if Diagnostics.isLoggingEnabled {
            let delay = max(0, (Double(mach_absolute_time()) * nanosecondsPerTick - Double(timestamp)) / 1_000_000)
            if delay > 50 {
                Diagnostics.note(String(format: "event type=%d delivered %.0f ms late", type.rawValue, delay))
            }
        }
        consume = tap.handle(type: type, flags: flags, key: key, text: text)
    }
    return consume ? nil : Unmanaged.passUnretained(event)
}

@MainActor
final class HotkeyTap {
    private let switcher: Switcher
    private let host: WindowActionHost
    private var machPort: CFMachPort?
    private var source: CFRunLoopSource?
    private var keyboard = HotkeyState()

    var bindings: [Chord: Action] {
        get { keyboard.bindings }
        set { switcher.cancel(); keyboard.bindings = newValue }
    }

    init(switcher: Switcher, host: WindowActionHost) {
        self.switcher = switcher
        self.host = host
    }

    var diagnosticSummary: String {
        let enabled = machPort.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        let keys = bindings.map { "\($0.key.display)=\($0.value)" }.sorted().joined(separator: ", ")
        return "Tap: created=\(machPort != nil) enabled=\(enabled) hold=\(keyboard.hold?.rawValue.description ?? "nil") bindings=[\(keys)]"
    }

    @discardableResult
    func start() -> Bool {
        guard machPort == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return false }

        machPort = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        Diagnostics.note(diagnosticSummary)
        return true
    }

    /// Remove the source before the unretained callback pointer becomes invalid.
    func stop() {
        guard let machPort else { return }
        CGEvent.tapEnable(tap: machPort, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(machPort)
        self.source = nil
        self.machPort = nil
    }

    fileprivate func handle(type: CGEventType, flags: CGEventFlags, key: UInt16, text: String?) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Diagnostics.error("tap disabled type=\(type.rawValue); re-enabling")
            if let machPort { CGEvent.tapEnable(tap: machPort, enable: true) }
            return false
        }
        let input: HotkeyState.Event
        switch type {
        case .keyDown: input = .keyDown
        case .keyUp: input = .keyUp
        case .flagsChanged: input = .flagsChanged
        default: return false
        }
        var modifiers = Chord.Modifiers()
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }

        let acceptsFilterInput = switcher.acceptsFilterInput
        let command = keyboard.handle(input, key: key, modifiers: modifiers,
                                      text: text, acceptsFilterInput: acceptsFilterInput)
        if command != .pass {
            Diagnostics.note("key type=\(type.rawValue) key=\(key) modifiers=\(modifiers.rawValue) command=\(command)")
        }
        switch command {
        case .pass, .consume: break
        case .start(let mode, let trigger, let reversed):
            HUDPanel.modifierHint = trigger.modifierDisplay
            switcher.start(mode, reversed: reversed)
        case .finish(let commit, _):
            if commit { switcher.commit() } else { switcher.cancel() }
        case .step(let delta, let wrap):
            switcher.step(wrap ? delta : delta * switcher.pageSize, wrap: wrap)
        case .toggleScope: switcher.toggleScope()
        case .appendFilterText(let text): switcher.appendFilterText(text)
        case .deleteFilterCharacter: switcher.deleteFilterCharacter()
        case .perform(let action):
            // Defer AX requests and process creation to avoid an event tap timeout.
            DispatchQueue.main.async { [host] in host.run(action) }
        }
        return command.consumesEvent
    }
}
