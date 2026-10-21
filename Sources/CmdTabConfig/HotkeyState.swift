import Carbon.HIToolbox

/// Routes keyboard events without an event tap or a WindowServer connection.
public struct HotkeyState {
    public enum Event { case keyDown, keyUp, flagsChanged }
    public enum Command: Equatable {
        case pass
        case consume
        case start(SwitchMode, Chord, reversed: Bool)
        case finish(commit: Bool, consume: Bool)
        case step(Int, wrap: Bool)
        case toggleScope
        case appendFilterText(String)
        case deleteFilterCharacter
        case perform(Action)

        public var consumesEvent: Bool {
            switch self {
            case .pass: false
            case .finish(_, let consume): consume
            default: true
            }
        }
    }

    public var bindings: [Chord: Action] = [:] {
        didSet { hold = nil; mode = nil }
    }
    public private(set) var hold: Chord.Modifiers?
    private var mode: SwitchMode?
    private var consumedKeys: Set<UInt16> = []

    public init() {}

    public mutating func handle(_ event: Event, key: UInt16, modifiers: Chord.Modifiers,
                                text: String? = nil, acceptsFilterInput: Bool = false) -> Command {
        let consumedRelease = event == .keyUp && consumedKeys.remove(key) != nil
        if let hold, !modifiers.isSuperset(of: hold) {
            self.hold = nil
            mode = nil
            // Recover if the system discarded the modifier release while the tap was disabled.
            return .finish(commit: true, consume: consumedRelease)
        }
        if event == .flagsChanged { return .pass }
        if event == .keyUp { return consumedRelease ? .consume : .pass }

        let chord = Chord(keyCode: key, modifiers: modifiers)
        if let mode {
            consumedKeys.insert(key)
            let reverse = modifiers.contains(.shift)
            // Trigger keys take precedence over the fixed navigation keys.
            if let entry = bindings.first(where: { entry in
                if case .switcher = entry.value { return entry.key.keyCode == key }
                return false
            }), case .switcher(let target) = entry.value {
                let delta = target == mode ? 1 : -1
                return .step(reverse ? -delta : delta, wrap: true)
            }
            switch Int(key) {
            case kVK_Escape: return finish(commit: false)
            case kVK_Return, kVK_ANSI_KeypadEnter: return finish(commit: true)
            case kVK_RightArrow: return .toggleScope
            case kVK_DownArrow: return .step(1, wrap: true)
            case kVK_UpArrow: return .step(-1, wrap: true)
            case kVK_PageDown: return .step(1, wrap: false)
            case kVK_PageUp: return .step(-1, wrap: false)
            case kVK_Delete: return acceptsFilterInput ? .deleteFilterCharacter : .consume
            default:
                guard acceptsFilterInput, let text, Self.isFilterText(text) else { return .consume }
                return .appendFilterText(text)
            }
        }

        let unshifted = chord.removing(.shift)
        if case .switcher(let mode) = bindings[unshifted] {
            hold = unshifted.modifiers
            self.mode = mode
            consumedKeys.insert(key)
            return .start(mode, unshifted, reversed: modifiers.contains(.shift))
        }
        if let action = bindings[chord] {
            consumedKeys.insert(key)
            return .perform(action)
        }
        return .pass
    }

    private mutating func finish(commit: Bool) -> Command {
        hold = nil
        mode = nil
        return .finish(commit: commit, consume: true)
    }

    private static func isFilterText(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: false
            // AppKit represents function and navigation keys with private-use characters.
            default: !(0xF700...0xF8FF).contains(scalar.value)
            }
        }
    }
}
