import Foundation
import CmdTabModel

/// The text in the menu bar.
public enum MenuIcon: Sendable, Equatable {
    case desktopNumber
    case literal(String)
}

/// The configuration snapshot. Invalid entries produce errors. Other entries remain available.
public struct Config: Sendable {
    public let bindings: [Chord: Action]
    public let menuIcon: MenuIcon
    public let errors: [String]

    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/cmdtab/config.json")

    private static let switchers: [(name: String, mode: SwitchMode, trigger: String)] = [
        ("switch-all-windows", .allWindows, "cmd-tab"),
        ("switch-current-app", .currentApp, "cmd-grave"),
    ]

    public static var defaults: Config { parse(Data("{}".utf8)) }

    public static func load(from url: URL = defaultURL) -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return defaults }
        do { return parse(try Data(contentsOf: url)) }
        catch { return Config(bindings: defaults.bindings, menuIcon: .desktopNumber,
                              errors: ["could not read \(url.path): \(error.localizedDescription)"]) }
    }

    public static func parse(_ data: Data) -> Config {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Config(bindings: defaults.bindings, menuIcon: .desktopNumber,
                          errors: ["not a JSON object"])
        }
        var errors: [String] = []
        var bindings: [Chord: Action] = [:]
        let known = ["keys", "menu"] + switchers.map(\.name)
        for key in root.keys.sorted() where !known.contains(key) {
            errors.append("unknown section \"\(key)\"")
        }

        func section(_ name: String, fields: [String]? = nil) -> [String: Any] {
            guard let value = root[name] else { return [:] }
            guard let object = value as? [String: Any] else {
                errors.append("\(name): must be an object")
                return [:]
            }
            if let fields {
                for key in object.keys.sorted() where !fields.contains(key) {
                    errors.append("unknown field \"\(key)\" in \(name)")
                }
            }
            return object
        }

        func chord(_ text: String) throws -> Chord {
            let chord = try Chord(parsing: text)
            guard !chord.modifiers.contains(.function) else {
                throw ConfigError("fn cannot be bound: arrow and function keys set it automatically")
            }
            return chord
        }

        // Validate both triggers before local bindings. Shift belongs to reverse traversal.
        let defaultChords = switchers.map { try! Chord(parsing: $0.trigger) }
        var triggers = defaultChords
        for (index, switcher) in switchers.enumerated() {
            let object = section(switcher.name, fields: ["trigger"])
            let fallback = defaultChords[index]
            var trigger = fallback
            if let value = object["trigger"] {
                do {
                    guard let text = value as? String else { throw ConfigError("must be a string") }
                    let candidate = try chord(text)
                    guard !candidate.modifiers.subtracting(.shift).isEmpty else {
                        throw ConfigError("needs at least one of cmd/ctrl/alt")
                    }
                    guard !candidate.modifiers.contains(.shift) else {
                        throw ConfigError("Shift reverses traversal and cannot be part of a trigger")
                    }
                    trigger = candidate
                } catch { errors.append("\(switcher.name).trigger: \(error)") }
            }
            triggers[index] = trigger
        }
        if triggers[0].keyCode == triggers[1].keyCode {
            errors.append("switcher trigger keys must differ; restored both default triggers")
            triggers = defaultChords
        }
        for (switcher, trigger) in zip(switchers, triggers) {
            bindings[trigger] = .switcher(switcher.mode)
        }

        let keys = section("keys")
        for text in keys.keys.sorted() {
            do {
                guard let spec = keys[text] as? String else { throw ConfigError("value must be a string") }
                let key = try chord(text)
                let action = try action(for: spec)
                let reversedTrigger = key.modifiers.contains(.shift)
                    && bindings[key.removing(.shift)].map { if case .switcher = $0 { true } else { false } } == true
                guard bindings[key] == nil, !reversedTrigger else {
                    throw ConfigError("chord already bound to another action")
                }
                bindings[key] = action
            } catch { errors.append("keys.\(text): \(error)") }
        }

        let menu = section("menu", fields: ["icon"])
        var icon = MenuIcon.desktopNumber
        if let value = menu["icon"] {
            if let text = value as? String {
                icon = text == "desktop-number" ? .desktopNumber : .literal(text)
            } else { errors.append("menu.icon: must be a string") }
        }
        return Config(bindings: bindings, menuIcon: icon, errors: errors)
    }

    static func action(for spec: String) throws -> Action {
        switch spec {
        case "toggle-fullscreen": return .toggleFullScreen
        case "toggle-maximize": return .toggleMaximize
        default: break
        }
        let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw ConfigError("unknown action \"\(spec)\"") }
        let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        switch parts[0] {
        case "shell", "applescript":
            guard !value.isEmpty else { throw ConfigError("\(parts[0]): has no command") }
            return parts[0] == "shell" ? .shell(value) : .appleScript(value)
        case "tile":
            if value == "center" { return .center }
            guard let edge = WindowEdge(rawValue: value) else {
                throw ConfigError("tile: expected left/right/top/bottom/center, got \"\(value)\"")
            }
            return .tile(edge)
        case "switch-desktop":
            if value == "previous" { return .desktop(.previous) }
            if value == "next" { return .desktop(.next) }
            guard let number = Int(value), (1...16).contains(number) else {
                throw ConfigError("switch-desktop: expected 1-16, previous or next, got \"\(value)\"")
            }
            return .desktop(.number(number))
        default: throw ConfigError("unknown action \"\(spec)\"")
        }
    }
}

private struct ConfigError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
