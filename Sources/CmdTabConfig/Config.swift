import Foundation

/// The content of the menu bar item.
public enum MenuIcon: Sendable, Equatable {
    /// The number of the active desktop. A full-screen Space has no number, so
    /// the item shows the tab glyph.
    case desktopNumber
    /// The item shows this text without change.
    case literal(String)

    static let desktopNumberKeyword = "desktop-number"
}

/// A chord and the action that it runs.
public struct Binding: Sendable {
    public let chord: Chord
    public let action: any Action
}

/// The parsed form of `~/.config/cmdtab/config.json`.
///
/// No error is fatal. Examples are a malformed file, an incorrect chord or an
/// unknown action name. Only the incorrect binding is missing, and `errors`
/// tells why. Thus, a typo in one entry does not remove the switcher.
public struct Config: Sendable {
    public let bindings: [Binding]
    public let menuIcon: MenuIcon
    public let errors: [String]

    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/cmdtab/config.json")

    static let switcherSections: [(key: String, mode: SwitchMode, defaultTrigger: String)] = [
        ("switch-all-windows", .allWindows, "cmd-tab"),
        ("switch-current-app", .currentApp, "cmd-grave"),
    ]
    static let knownSections = ["keys", "menu"] + switcherSections.map(\.key)

    /// The configuration if there is no config file.
    public static var defaults: Config {
        Config(bindings: switcherDefaults(), menuIcon: .desktopNumber, errors: [])
    }

    private static func switcherDefaults() -> [Binding] {
        switcherSections.compactMap { section in
            guard let chord = try? Chord(parsing: section.defaultTrigger) else { return nil }
            return Binding(chord: chord, action: SwitcherAction(mode: section.mode))
        }
    }

    public static func load(from url: URL = defaultURL) -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return defaults }
        guard let data = try? Data(contentsOf: url) else {
            return Config(bindings: switcherDefaults(), menuIcon: .desktopNumber,
                          errors: ["could not read \(url.path)"])
        }
        return parse(data)
    }

    public static func parse(_ data: Data) -> Config {
        var errors: [String] = []
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Config(bindings: switcherDefaults(), menuIcon: .desktopNumber,
                          errors: ["not a JSON object"])
        }

        // `Decodable` ignores unknown keys, so it does not find a misspelled
        // section. Compare each name with the known sections.
        for key in root.keys.sorted() where !knownSections.contains(key) {
            errors.append("unknown section \"\(key)\"")
        }

        var bindings: [Binding] = []
        var claimed: [Chord: String] = [:]

        /// The `keys` table and the switcher triggers both use this function.
        /// Thus, they use the same chord checks and the same conflict errors.
        @discardableResult
        func bind(chordText: String, action: any Action, origin: String) -> Bool {
            let chord: Chord
            do {
                chord = try Chord(parsing: chordText)
            } catch {
                errors.append("\(origin): \(error)")
                return false
            }
            if chord.modifiers.contains(.function) {
                errors.append("\(origin): fn cannot be bound — arrow and function keys set "
                    + "it implicitly, so an event tap cannot tell a real fn from that")
                return false
            }
            if let owner = claimed[chord] {
                errors.append("\(origin): chord already bound to \(owner)")
                return false
            }
            claimed[chord] = action.name
            bindings.append(Binding(chord: chord, action: action))
            return true
        }

        if let keys = section(root, "keys", &errors) {
            // Sort the keys, so that a duplicate chord gives the same error each time.
            for chordText in keys.keys.sorted() {
                guard let spec = keys[chordText] as? String else {
                    errors.append("keys.\(chordText): value must be a string")
                    continue
                }
                do {
                    bind(chordText: chordText, action: try action(for: spec), origin: "keys.\(chordText)")
                } catch {
                    errors.append("keys.\(chordText): \(error)")
                }
            }
        }

        for s in switcherSections {
            var trigger = s.defaultTrigger
            if let object = section(root, s.key, &errors) {
                for key in object.keys.sorted() where key != "trigger" {
                    errors.append("unknown field \"\(key)\" in \(s.key)")
                }
                if let value = object["trigger"] {
                    if let text = value as? String {
                        trigger = text
                    } else {
                        errors.append("\(s.key).trigger: must be a string")
                    }
                }
            }

            // The release of the trigger modifiers ends a cycle. Thus, a trigger
            // without modifiers starts a cycle that cannot end.
            var usable = true
            if let chord = try? Chord(parsing: trigger),
               chord.modifiers.intersection(.tapMatchable).isEmpty {
                errors.append("\(s.key).trigger: \"\(trigger)\" needs at least one of "
                    + "cmd/ctrl/alt/shift — releasing it is what commits the switch")
                usable = false
            }

            if usable, bind(chordText: trigger, action: SwitcherAction(mode: s.mode),
                            origin: "\(s.key).trigger") {
                continue
            }
            // If the configured trigger is not usable, use the default trigger.
            // Without a switcher, the user cannot switch windows to correct the JSON.
            if trigger != s.defaultTrigger {
                bind(chordText: s.defaultTrigger, action: SwitcherAction(mode: s.mode),
                     origin: "\(s.key).trigger fallback")
            }
        }

        var icon = MenuIcon.desktopNumber
        if let menu = section(root, "menu", &errors) {
            for key in menu.keys.sorted() where key != "icon" {
                errors.append("unknown field \"\(key)\" in menu")
            }
            if let value = menu["icon"] {
                if let text = value as? String {
                    icon = text == MenuIcon.desktopNumberKeyword ? .desktopNumber : .literal(text)
                } else {
                    errors.append("menu.icon: must be a string")
                }
            }
        }

        return Config(bindings: bindings, menuIcon: icon, errors: errors)
    }

    private static func section(_ root: [String: Any], _ key: String,
                                _ errors: inout [String]) -> [String: Any]? {
        guard let raw = root[key] else { return nil }
        guard let object = raw as? [String: Any] else {
            errors.append("\(key): must be an object")
            return nil
        }
        return object
    }

    /// An action is a name or `<name>:<parameter>`. Actions with a parameter
    /// use this format also if the set of values is small. Thus, a new
    /// direction or desktop is a new value, not a new name.
    static func action(for spec: String) throws -> any Action {
        if let command = spec.dropPrefix("shell:") {
            guard !command.isEmpty else { throw ActionError.emptyCommand("shell") }
            return ShellAction(command: command)
        }
        if let source = spec.dropPrefix("applescript:") {
            guard !source.isEmpty else { throw ActionError.emptyCommand("applescript") }
            return AppleScriptAction(source: source)
        }
        if let direction = spec.dropPrefix("tile:") {
            if direction == "center" { return CenterAction() }
            guard let edge = WindowEdge(rawValue: direction) else {
                throw ActionError.badParameter(
                    "tile", direction,
                    (WindowEdge.allCases.map(\.rawValue) + ["center"]).joined(separator: "/"))
            }
            return TileAction(edge: edge)
        }
        if let target = spec.dropPrefix("switch-desktop:") {
            return SwitchDesktopAction(target: try desktop(target))
        }
        if let action = builtins[spec] { return action() }
        throw ActionError.unknownAction(spec)
    }

    private static func desktop(_ text: String) throws -> SwitchDesktopAction.Target {
        switch text {
        case "previous": return .step(-1)
        case "next": return .step(1)
        default: break
        }
        // macOS lets a display have a maximum of 16 Spaces. A number larger than
        // the number of Spaces is valid and does nothing, as with the system
        // shortcuts.
        guard let n = Int(text), (1...16).contains(n) else {
            throw ActionError.badParameter("switch-desktop", text, "1-16, previous or next")
        }
        return .desktop(n)
    }

    /// The actions without a parameter. Each value is a factory, so two chords
    /// with the same action get different objects.
    static let builtins: [String: @Sendable () -> any Action] = [
        "toggle-fullscreen": { ToggleAction(kind: .fullscreen) },
        "toggle-maximize": { ToggleAction(kind: .maximize) },
    ]

    enum ActionError: Error, Equatable, CustomStringConvertible {
        case unknownAction(String)
        case emptyCommand(String)
        /// A known action with a parameter value that is not valid.
        case badParameter(String, String, String)

        var description: String {
            switch self {
            case .unknownAction(let s): "unknown action \"\(s)\""
            case .emptyCommand(let p): "\(p): has no command"
            case .badParameter(let action, let value, let expected):
                "\(action): expected \(expected), got \"\(value)\""
            }
        }
    }
}

private extension String {
    /// The text after `prefix`, or `nil` if the text does not start with
    /// `prefix`. It removes the whitespace around the result, so
    /// `"shell: open -a Finder"` also works.
    func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}
