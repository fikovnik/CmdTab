import Foundation
import CmdTabModel

public enum MenuIcon: Sendable, Equatable {
    case desktopNumber
    case literal(String)
}

/// Keep valid entries when other entries have errors.
public struct Config: Sendable {
    public let bindings: [Chord: Action]
    public let menuIcon: MenuIcon
    public let errors: [String]

    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/cmdtab/config.json")

    private static let switchers: [(name: String, mode: SwitchMode, trigger: String)] = [
        ("switch-all-windows", .allWindows, "cmd-tab"),
        ("switch-app-windows", .currentApp, "cmd-grave"),
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
        let known = ["keys", "menu"]
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

        // Reserve switcher shortcuts before you add local bindings.
        let defaultChords = switchers.map { try! Chord(parsing: $0.trigger) }
        var customTriggers: [Chord?] = switchers.map { _ in nil }
        var localBindings: [(text: String, key: Chord, action: Action)] = []
        let keys = section("keys")
        for text in keys.keys.sorted() {
            do {
                guard let spec = keys[text] as? String else { throw ConfigError("value must be a string") }
                let key = try chord(text)
                let action = try action(for: spec)
                if let index = switchers.firstIndex(where: { action == .switcher($0.mode) }) {
                    guard !key.modifiers.subtracting(.shift).isEmpty else {
                        throw ConfigError("needs at least one of cmd/ctrl/alt")
                    }
                    guard !key.modifiers.contains(.shift) else {
                        throw ConfigError("Shift reverses traversal and cannot be part of a trigger")
                    }
                    guard customTriggers[index] == nil else {
                        throw ConfigError("\(spec) already has a trigger")
                    }
                    customTriggers[index] = key
                } else {
                    localBindings.append((text, key, action))
                }
            } catch { errors.append("keys.\(text): \(error)") }
        }
        var triggers = zip(customTriggers, defaultChords).map { $0 ?? $1 }
        if triggers[0].keyCode == triggers[1].keyCode {
            errors.append("switcher trigger keys must differ; restored both default triggers")
            triggers = defaultChords
        }
        for (switcher, trigger) in zip(switchers, triggers) {
            bindings[trigger] = .switcher(switcher.mode)
        }

        for (text, key, action) in localBindings {
            do {
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
        if let switcher = switchers.first(where: { $0.name == spec }) {
            return .switcher(switcher.mode)
        }
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
        case "move-to-display":
            guard let direction = DisplayDirection(rawValue: value) else {
                throw ConfigError("move-to-display: expected previous or next, got \"\(value)\"")
            }
            return .moveToDisplay(direction)
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
