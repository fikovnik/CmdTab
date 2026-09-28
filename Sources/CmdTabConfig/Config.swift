import Foundation

/// What the menu bar item shows.
public enum MenuIcon: Sendable, Equatable {
    /// The active desktop number, falling back to the tab glyph on a
    /// full-screen Space, which has no number.
    case desktopNumber
    /// Shown verbatim.
    case literal(String)

    static let desktopNumberKeyword = "desktop-number"
}

public struct Binding: Sendable {
    public let chord: Chord
    public let action: any Action
}

/// `~/.config/cmdtab/config.json`, parsed.
///
/// Nothing here is fatal. A missing file, a malformed file, a bad chord or an
/// unknown action name all degrade to "that one binding is missing, and there
/// is an entry in `errors` saying why". Losing the switcher because of a typo
/// four lines further down would be a poor trade.
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

    /// The behaviour with no config file at all: exactly what CmdTab did before
    /// there was one.
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

        // Decodable would silently drop a misspelled section, and these
        // sections exist to be extended, so check the names explicitly.
        for key in root.keys.sorted() where !knownSections.contains(key) {
            errors.append("unknown section \"\(key)\"")
        }

        var bindings: [Binding] = []
        var claimed: [Chord: String] = [:]

        /// Shared by the `keys` table and the switcher triggers so that chord
        /// validation and conflict reporting cannot drift apart.
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
            // Sorted so that a duplicate chord reports the same way every run.
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

            // A cycle is committed by releasing the trigger's modifiers, so a
            // trigger without any would start a cycle nothing could end.
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
            // Fall back to the default rather than leaving the switcher
            // unbound: losing Cmd+Tab to a typo would mean editing JSON with no
            // way to switch windows.
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

    static func action(for spec: String) throws -> any Action {
        if let command = spec.dropPrefix("shell:") {
            guard !command.isEmpty else { throw ActionError.emptyCommand("shell") }
            return ShellAction(command: command)
        }
        if let source = spec.dropPrefix("applescript:") {
            guard !source.isEmpty else { throw ActionError.emptyCommand("applescript") }
            return AppleScriptAction(source: source)
        }
        if let action = builtins[spec] { return action() }
        throw ActionError.unknownAction(spec)
    }

    /// Everything CmdTab implements itself. Each value is a factory rather than
    /// a shared instance, so two chords bound to the same action do not share
    /// one object.
    static let builtins: [String: @Sendable () -> any Action] = {
        var t: [String: @Sendable () -> any Action] = [:]

        for edge in WindowEdge.allCases {
            t["\(edge.rawValue)-half"] = { TileAction(edge: edge) }
        }
        t["toggle-fullscreen"] = { ToggleAction(kind: .fullscreen) }
        t["toggle-maximize"] = { ToggleAction(kind: .maximize) }

        // macOS allows 16 Spaces per display. A number past however many you
        // actually have is accepted and does nothing, same as the system's own
        // shortcuts.
        for n in 1...16 {
            t["desktop-\(n)"] = { SpaceAction(target: .desktop(n), name: "desktop-\(n)") }
        }
        t["space-previous"] = { SpaceAction(target: .step(-1), name: "space-previous") }
        t["space-next"] = { SpaceAction(target: .step(1), name: "space-next") }

        return t
    }()

    enum ActionError: Error, Equatable, CustomStringConvertible {
        case unknownAction(String)
        case emptyCommand(String)

        var description: String {
            switch self {
            case .unknownAction(let s): "unknown action \"\(s)\""
            case .emptyCommand(let p): "\(p): has no command"
            }
        }
    }
}

private extension String {
    /// The remainder after `prefix`, or nil if it is not there. Trims the
    /// leading space in `"shell: open -a Finder"` so both spellings work.
    func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}
