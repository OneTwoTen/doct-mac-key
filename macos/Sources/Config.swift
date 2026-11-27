import Foundation

/// How the composition is presented to the host application (docs/SPEC.md §7.2).
enum InsertMode: String, CaseIterable {
    /// Default: `setMarkedText` / `commitMarkedText` — the app shows the
    /// composition as underlined/selected marked text.
    case marked
    /// Direct: characters go straight into the document and the IME replaces
    /// the tracked trailing text on every change.
    case direct

    var displayName: String {
        switch self {
        case .marked: return "Marked (mặc định)"
        case .direct: return "Direct"
        }
    }
}

/// A hotkey spec parsed into Carbon terms: virtual key code + Carbon modifier mask.
struct ParsedHotkey: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    // Carbon modifier masks (Events.h: cmdKey, shiftKey, optionKey, controlKey).
    static let commandMask: UInt32 = 0x0100
    static let shiftMask: UInt32 = 0x0200
    static let optionMask: UInt32 = 0x0800
    static let controlMask: UInt32 = 0x1000
}

/// User configuration persisted at `~/.config/doctkey/config.json`.
///
/// The file also carries the host-side `insert_mode` and `hotkeys` sections that
/// the Rust engine never sees. Unknown keys in the file are preserved verbatim on
/// save, so newer versions can add fields without this version clobbering them.
/// Invalid JSON is logged and ignored: the app keeps safe defaults instead of
/// crashing or overwriting the user's file on load.
final class Config {
    static let defaultHotkeys: [String: String] = [
        "toggle_mode": "ctrl+alt+v",
        "toggle_method": "ctrl+alt+t",
        "toggle_tone_style": "ctrl+alt+d",
        "toggle_smart": "ctrl+alt+e",
        "reload_config": "ctrl+alt+r"
    ]

    /// ANSI virtual key codes (Carbon kVK_*). Only the keys that make sense as
    /// hotkeys are listed; letters, digits and a few named keys.
    static let keyCodeMap: [String: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B,
        "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
        "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D,
        "]": 0x1E, "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23,
        "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29, "\\": 0x2A,
        ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F,
        "space": 0x31, "`": 0x32,
        "return": 0x24, "enter": 0x24, "tab": 0x30, "escape": 0x35, "esc": 0x35,
        "backspace": 0x33, "delete": 0x33,
        "forwarddelete": 0x75,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60,
        "f6": 0x61, "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D,
        "f11": 0x67, "f12": 0x6F
    ]

    /// Default config path: `~/.config/doctkey/config.json`.
    static var defaultPath: String {
        NSHomeDirectory() + "/.config/doctkey/config.json"
    }

    let path: String

    // Engine settings (mirrored from engine results whenever they change).
    var mode: String = "vi"
    var method: String = "telex"
    var toneStyle: String = "modern"
    var smartEnglish: Bool = true

    // Host settings.
    var insertMode: InsertMode = .marked
    /// Global CGEventTap compatibility mode (signing-independent fallback).
    /// Persisted as `compat_mode`; the engine never sees this field.
    var compatMode: Bool = false
    private(set) var hotkeys: [String: String] = Config.defaultHotkeys

    /// Last JSON object read from disk, kept so unknown keys survive a save().
    private var rawObject: [String: Any] = [:]
    private let saveQueue = DispatchQueue(label: "com.doct.doctkey.config-save", qos: .utility)
    private var pendingSaveWorkItem: DispatchWorkItem?

    init(path: String = Config.defaultPath) {
        self.path = path
        load()
    }

    /// JSON handed to the Rust engine — engine fields only.
    var engineJSON: String {
        let safeMode = (mode == "en") ? "en" : "vi"
        let safeMethod = (method == "vni") ? "vni" : "telex"
        let safeTone = (toneStyle == "traditional") ? "traditional" : "modern"
        let smart = smartEnglish ? "true" : "false"
        return "{\"mode\":\"\(safeMode)\",\"method\":\"\(safeMethod)\",\"tone_style\":\"\(safeTone)\",\"smart_english\":\(smart)}"
    }

    /// Loads the file (creating a default one when absent). Invalid content is
    /// logged and ignored rather than fatal.
    func load() {
        let manager = FileManager.default
        if let data = manager.contents(atPath: path) {
            if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                rawObject = object
            } else {
                NSLog("DoctKey: invalid JSON in \(path); keeping defaults")
                rawObject = [:]
            }
        } else {
            rawObject = [:]
            // Create the default file so "open config" always has something to show.
            save()
            return
        }
        apply(rawObject)
    }

    private func buildSaveData() -> (data: Data, snapshot: [String: Any])? {
        var object = rawObject
        object["mode"] = mode
        object["method"] = method
        object["tone_style"] = toneStyle
        object["smart_english"] = smartEnglish
        object["insert_mode"] = insertMode.rawValue
        object["compat_mode"] = compatMode
        object["hotkeys"] = hotkeys

        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return (data, object)
    }

    private static func writeAtomic(data: Data, to path: String) {
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            NSLog("DoctKey: could not write config \(path): \(error)")
        }
    }

    /// Persists the current values synchronously, preserving unknown keys already on disk.
    func save() {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        guard let payload = buildSaveData() else {
            NSLog("DoctKey: could not encode config for \(path)")
            return
        }
        rawObject = payload.snapshot
        let targetPath = path
        saveQueue.sync {
            Config.writeAtomic(data: payload.data, to: targetPath)
        }
    }

    /// Debounced background persistence for rapid interactive toggles.
    func saveAsync(debounce: TimeInterval = 0.15) {
        pendingSaveWorkItem?.cancel()
        guard let payload = buildSaveData() else {
            NSLog("DoctKey: could not encode config for \(path)")
            return
        }
        rawObject = payload.snapshot
        let targetPath = path
        let data = payload.data
        let workItem = DispatchWorkItem {
            Config.writeAtomic(data: data, to: targetPath)
        }
        pendingSaveWorkItem = workItem
        saveQueue.asyncAfter(deadline: .now() + debounce, execute: workItem)
    }

    /// Ensures any scheduled async save has been flushed to disk.
    func flushPendingSave() {
        if pendingSaveWorkItem != nil {
            save()
        } else {
            saveQueue.sync {}
        }
    }

    // MARK: - Hotkeys

    /// Display order of the five global hotkeys (also the settings-window order).
    static let hotkeyFieldOrder = [
        "toggle_mode",
        "toggle_method",
        "toggle_tone_style",
        "toggle_smart",
        "reload_config"
    ]

    /// Vietnamese titles for the hotkey fields, used by the settings window and
    /// by validation error messages.
    static let hotkeyFieldTitles: [String: String] = [
        "toggle_mode": "Bật/tắt tiếng Việt",
        "toggle_method": "Đổi kiểu gõ Telex/VNI",
        "toggle_tone_style": "Đổi kiểu đặt dấu",
        "toggle_smart": "Bật/tắt ưu tiên tiếng Việt",
        "reload_config": "Nạp lại cấu hình"
    ]

    /// Canonical form for comparison/persistence: lowercase, no spaces around
    /// the "+" separators, no leading/trailing whitespace.
    static func normalizedHotkey(_ spec: String) -> String {
        spec.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "+")
    }

    private static func isModifierToken(_ token: String) -> Bool {
        switch token {
        case "ctrl", "control", "alt", "opt", "option", "cmd", "command",
             "shift", "fn", "function":
            return true
        default:
            return false
        }
    }

    /// Human-readable form of a hotkey spec, e.g. `"ctrl+alt+v"` → `"⌃⌥V"`.
    /// Never returns nil: partial/invalid specs are rendered best-effort.
    static func formatHotkey(_ spec: String) -> String {
        let normalized = normalizedHotkey(spec)
        guard !normalized.isEmpty else { return "" }
        let tokens = normalized.split(separator: "+", omittingEmptySubsequences: false).map(String.init)

        var symbols = ""
        if let parsed = parseHotkey(normalized) {
            if parsed.modifiers & ParsedHotkey.controlMask != 0 { symbols += "⌃" }
            if parsed.modifiers & ParsedHotkey.optionMask != 0 { symbols += "⌥" }
            if parsed.modifiers & ParsedHotkey.shiftMask != 0 { symbols += "⇧" }
            if parsed.modifiers & ParsedHotkey.commandMask != 0 { symbols += "⌘" }
        }
        guard let keyToken = tokens.last(where: { !isModifierToken($0) }) else { return symbols }

        let keyName: String
        switch keyToken {
        case "space": keyName = "Space"
        case "return", "enter": keyName = "↩"
        case "tab": keyName = "⇥"
        case "escape", "esc": keyName = "⎋"
        case "backspace", "delete": keyName = "⌫"
        case "forwarddelete": keyName = "⌦"
        case "left": keyName = "←"
        case "right": keyName = "→"
        case "up": keyName = "↑"
        case "down": keyName = "↓"
        case "home": keyName = "Home"
        case "end": keyName = "End"
        case "pageup": keyName = "Page Up"
        case "pagedown": keyName = "Page Down"
        default: keyName = keyToken.uppercased()
        }
        return symbols + keyName
    }

    /// Validates a full hotkey set. Keys are the five field names from
    /// `hotkeyFieldOrder`; values are Vietnamese error messages. An empty result
    /// means every entry is syntactically valid, has at least one modifier and is
    /// unique (registration can still fail if another app owns the shortcut).
    static func validateHotkeys(_ specs: [String: String]) -> [String: String] {
        var errors: [String: String] = [:]
        var byBinding: [String: [String]] = [:]

        for field in hotkeyFieldOrder {
            let raw = specs[field] ?? ""
            let normalized = normalizedHotkey(raw)
            if normalized.isEmpty {
                errors[field] = "Phím tắt không được để trống."
                continue
            }
            guard let parsed = parseHotkey(normalized) else {
                errors[field] = "Không hợp lệ — dùng dạng như ctrl+alt+v."
                continue
            }
            if parsed.modifiers == 0 {
                errors[field] = "Cần ít nhất một phím bổ trợ (ctrl, alt, cmd hoặc shift)."
                continue
            }
            let bindingKey = "\(parsed.keyCode):\(parsed.modifiers)"
            byBinding[bindingKey, default: []].append(field)
        }

        for fields in byBinding.values where fields.count > 1 {
            for field in fields {
                let otherNames = fields
                    .filter { $0 != field }
                    .compactMap { hotkeyFieldTitles[$0] }
                    .sorted()
                    .joined(separator: ", ")
                errors[field] = "Trùng phím tắt với: \(otherNames)."
            }
        }
        return errors
    }

    /// Merges new hotkey specs into the defaults, normalising them. Empty values
    /// fall back to the default for that field so a cleared UI field never
    /// silently disables the shortcut.
    func updateHotkeys(_ values: [String: String]) {
        var merged = Config.defaultHotkeys
        for (field, spec) in values {
            let normalized = Config.normalizedHotkey(spec)
            if !normalized.isEmpty {
                merged[field] = normalized
            }
        }
        hotkeys = merged
    }

    /// Parses strings like `"ctrl+alt+v"` into a Carbon hotkey. Returns nil for
    /// anything unparseable so the caller can fall back / skip the binding.
    static func parseHotkey(_ spec: String) -> ParsedHotkey? {
        let normalized = spec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        var modifiers: UInt32 = 0
        var keyToken: String?
        for part in normalized.split(separator: "+", omittingEmptySubsequences: false) {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.isEmpty { return nil }
            switch token {
            case "ctrl", "control":
                modifiers |= ParsedHotkey.controlMask
            case "alt", "opt", "option":
                modifiers |= ParsedHotkey.optionMask
            case "cmd", "command":
                modifiers |= ParsedHotkey.commandMask
            case "shift":
                modifiers |= ParsedHotkey.shiftMask
            case "fn", "function":
                modifiers |= 1 << 23 // kCGEventFlagMaskSecondaryFn, ignored by Carbon
            default:
                // Only a single non-modifier token (the key) is allowed.
                if keyToken != nil { return nil }
                keyToken = token
            }
        }
        guard let keyToken, let keyCode = keyCodeMap[keyToken] else { return nil }
        return ParsedHotkey(keyCode: keyCode, modifiers: modifiers)
    }

    private func apply(_ object: [String: Any]) {
        if let value = object["mode"] as? String, value == "vi" || value == "en" { mode = value }
        if let value = object["method"] as? String, value == "telex" || value == "vni" { method = value }
        if let value = object["tone_style"] as? String,
           value == "modern" || value == "traditional" { toneStyle = value }
        if let value = object["smart_english"] as? Bool { smartEnglish = value }
        if let value = object["insert_mode"] as? String, let mode = InsertMode(rawValue: value) {
            insertMode = mode
        }
        if let value = object["compat_mode"] as? Bool { compatMode = value }

        var merged = Config.defaultHotkeys
        if let dict = object["hotkeys"] as? [String: Any] {
            for (name, value) in dict {
                if let spec = value as? String, !spec.isEmpty { merged[name] = spec }
            }
        }
        hotkeys = merged
    }
}
