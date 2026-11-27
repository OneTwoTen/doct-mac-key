import Foundation

/// A physical key event, deliberately independent from AppKit so the key
/// processing logic can be unit tested against a mock host.
struct KeyInput {
    /// The characters produced by the event (`NSEvent.characters`), already
    /// carrying their case. nil for non-printing keys.
    var characters: String?
    /// Hardware virtual key code (`NSEvent.keyCode`).
    var keyCode: UInt16
    var modifiers: KeyModifiers
    var isRepeat: Bool

    init(characters: String? = nil,
         keyCode: UInt16 = 0,
         modifiers: KeyModifiers = [],
         isRepeat: Bool = false) {
        self.characters = characters
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }
}

/// AppKit-independent modifier set.
struct KeyModifiers: OptionSet {
    let rawValue: UInt

    init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    static let shift = KeyModifiers(rawValue: 1 << 0)
    static let control = KeyModifiers(rawValue: 1 << 1)
    static let option = KeyModifiers(rawValue: 1 << 2)
    static let command = KeyModifiers(rawValue: 1 << 3)
    static let capsLock = KeyModifiers(rawValue: 1 << 4)
    static let function = KeyModifiers(rawValue: 1 << 5)
}

/// Everything the key handler needs from the text system. Implemented by the
/// InputMethodKit adapter in the app and by MockHost in the test runner.
protocol TextHost: AnyObject {
    /// Insert text at the caret.
    func insertText(_ text: String)
    /// Replace `utf16Length` UTF-16 units immediately before the caret.
    func replaceTrailing(_ utf16Length: Int, with text: String)
    /// Show `text` as marked (pre-edit) text.
    func setMarkedText(_ text: String)
    /// Replace the marked text with normal text (or insert at caret when there
    /// is no marked text) and clear the marked state.
    func commitMarkedText(with text: String)
}

/// macOS virtual key codes used by the handler.
enum KeyCode {
    static let backspace: UInt16 = 51
    static let tab: UInt16 = 48
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let escape: UInt16 = 53
    static let forwardDelete: UInt16 = 117

    static let home: UInt16 = 115
    static let end: UInt16 = 119
    static let pageUp: UInt16 = 116
    static let pageDown: UInt16 = 121
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126

    static let f1: UInt16 = 122
    static let f2: UInt16 = 120
    static let f3: UInt16 = 99
    static let f4: UInt16 = 118
    static let f5: UInt16 = 96
    static let f6: UInt16 = 97
    static let f7: UInt16 = 98
    static let f8: UInt16 = 100
    static let f9: UInt16 = 101
    static let f10: UInt16 = 109
    static let f11: UInt16 = 103
    static let f12: UInt16 = 111

    static let movementKeys: Set<UInt16> = [
        home, end, pageUp, pageDown, leftArrow, rightArrow, downArrow, upArrow
    ]
    static let fKeys: Set<UInt16> = [
        f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    ]
    static let specialKeys: Set<UInt16> = Set([
        backspace, tab, returnKey, keypadEnter, escape, forwardDelete,
        home, end, pageUp, pageDown, leftArrow, rightArrow, downArrow, upArrow
    ]).union(fKeys)

    static func isMovementOrFunctionKey(_ code: UInt16) -> Bool {
        switch code {
        case home, end, pageUp, pageDown, leftArrow, rightArrow, downArrow, upArrow,
             f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12:
            return true
        default:
            return false
        }
    }

    static func isSpecialKey(_ code: UInt16) -> Bool {
        switch code {
        case backspace, tab, returnKey, keypadEnter, escape, forwardDelete:
            return true
        default:
            return isMovementOrFunctionKey(code)
        }
    }
}

/// Host-agnostic key processing: takes a `KeyInput`, asks the engine and applies
/// the resulting operation to a `TextHost`. This is the part the fixture runner
/// exercises with a mock host, in both insert modes.
final class KeyHandler {
    private let core: DoctKeyCore
    private(set) var insertMode: InsertMode
    private weak var host: TextHost?

    /// Visible composition in *direct* mode; always "" in marked mode.
    private var shown: String = ""
    /// Whether the engine currently has an open composition.
    private(set) var isComposing: Bool = false

    init(core: DoctKeyCore, insertMode: InsertMode = .marked) {
        self.core = core
        self.insertMode = insertMode
    }

    var hasHost: Bool { host != nil }

    // MARK: - Host attachment

    /// Called when a client activates. A composition left over from a client
    /// that disappeared without a clean deactivate is dropped instead of being
    /// replayed into the new client.
    func attach(host: TextHost) {
        if isComposing {
            core.reset()
            isComposing = false
            shown = ""
        }
        self.host = host
    }

    func detach(host: TextHost) {
        if self.host === host {
            self.host = nil
        }
    }

    // MARK: - Key handling

    /// Processes one key event. Returns true when the key must be swallowed by
    /// the IME; false means the host must process it normally.
    func handle(_ input: KeyInput) -> Bool {
        // Command/control/option combinations always belong to the application.
        // End any composition first so no marked text is left behind.
        if input.modifiers.contains(.command)
            || input.modifiers.contains(.control)
            || input.modifiers.contains(.option) {
            if isComposing { commitComposition() }
            return false
        }

        if input.isRepeat {
            if isComposing {
                // Held Backspace auto-repeat: commit the current word so the
                // host deletes smoothly one visible character per repeat tick.
                if input.keyCode == KeyCode.backspace {
                    commitComposition()
                    return false
                }
                // Swallow auto-repeat of character keys while composing.
                if isCharacterKey(input) { return true }
            } else {
                // Nothing to compose: let the application handle repeats.
                return false
            }
        }

        switch input.keyCode {
        case KeyCode.backspace:
            return apply(core.feedKey(1))
        case KeyCode.forwardDelete:
            return apply(core.feedKey(2))
        case KeyCode.escape:
            return apply(core.feedKey(3))
        case KeyCode.returnKey, KeyCode.keypadEnter:
            return apply(core.feedKey(4))
        case KeyCode.tab:
            return apply(core.feedKey(5))
        case let code where KeyCode.isMovementOrFunctionKey(code):
            return apply(core.feedKey(6))
        default:
            break
        }

        guard let characters = input.characters else {
            return false
        }
        let scalars = characters.unicodeScalars
        guard let scalar = scalars.first else {
            return false
        }
        // Control characters are never input text.
        if scalar.value < 0x20 || scalar.value == 0x7F {
            return false
        }
        // Multi-scalar output (emoji, combining sequences) is not part of this
        // engine's alphabet: finish the word and let the application insert it
        // verbatim instead of feeding a partial scalar.
        if scalars.index(after: scalars.startIndex) != scalars.endIndex {
            if isComposing { commitComposition() }
            return false
        }
        return apply(core.feedChar(scalar.value, flags: flags(for: input.modifiers)))
    }

    // MARK: - Composition control

    /// Commits the composition immediately (focus loss, menu action, toggle).
    @discardableResult
    func commitComposition() -> KeyResult {
        let result = core.commit()
        applyResult(result)
        return result
    }

    /// Executes an engine command (toggle_mode, toggle_method, …) and applies
    /// its result. Any open composition is committed first: commands such as
    /// `toggle_tone_style` / `toggle_smart` re-render the word inside the
    /// engine, and without committing the host text would desynchronise from the
    /// engine state (document corruption in direct mode).
    @discardableResult
    func command(_ json: String) -> KeyResult {
        if isComposing {
            commitComposition()
        }
        let result = core.command(json)
        applyResult(result)
        return result
    }

    /// Switches insert mode. Any open composition is committed first so the
    /// same text stays on screen when the presentation changes.
    func setInsertMode(_ newMode: InsertMode) {
        guard newMode != insertMode else { return }
        if isComposing { commitComposition() }
        insertMode = newMode
    }

    /// Forgets composition state without changing the screen (used on close).
    func reset() {
        core.reset()
        isComposing = false
        shown = ""
    }

    // MARK: - Result application

    /// Applies an engine result to the attached host.
    func applyResult(_ result: KeyResult) {
        switch result.op {
        case .append:
            switch insertMode {
            case .marked:
                host?.setMarkedText(result.word)
            case .direct:
                host?.insertText(result.text)
                shown += result.text
            }

        case .replace:
            switch insertMode {
            case .marked:
                if result.composing {
                    host?.setMarkedText(result.word)
                } else {
                    // Composition ended (e.g. escape); show the restored text as
                    // plain text, not as marked text.
                    host?.commitMarkedText(with: result.word)
                }
            case .direct:
                replaceVisibleComposition(with: result.word, composing: result.composing)
            }

        case .commit:
            switch insertMode {
            case .marked:
                host?.commitMarkedText(with: result.text)
            case .direct:
                if shown.isEmpty {
                    if !result.text.isEmpty { host?.insertText(result.text) }
                } else if shown != result.text {
                    host?.replaceTrailing(shown.utf16.count, with: result.text)
                }
                shown = ""
            }

        case .pass, .none, .state:
            break
        }

        isComposing = result.composing
    }

    // MARK: - Helpers

    private func replaceVisibleComposition(with word: String, composing: Bool) {
        if shown != word {
            var oldIdx = shown.startIndex
            var newIdx = word.startIndex
            while oldIdx < shown.endIndex, newIdx < word.endIndex, shown[oldIdx] == word[newIdx] {
                oldIdx = shown.index(after: oldIdx)
                newIdx = word.index(after: newIdx)
            }
            let trailingOldUTF16 = shown[oldIdx...].utf16.count
            let suffixNew = newIdx < word.endIndex ? String(word[newIdx...]) : ""
            if trailingOldUTF16 > 0 {
                host?.replaceTrailing(trailingOldUTF16, with: suffixNew)
            } else if !suffixNew.isEmpty {
                host?.insertText(suffixNew)
            }
        }
        // Once the engine stops composing, the replacement text is plain text.
        shown = composing ? word : ""
    }

    @discardableResult
    private func apply(_ result: KeyResult) -> Bool {
        applyResult(result)
        return result.consumed
    }

    private func isCharacterKey(_ input: KeyInput) -> Bool {
        guard let characters = input.characters, !characters.isEmpty else { return false }
        return !KeyCode.isSpecialKey(input.keyCode)
    }

    private func flags(for modifiers: KeyModifiers) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.shift) { flags |= 1 }
        if modifiers.contains(.capsLock) { flags |= 2 }
        if modifiers.contains(.option) { flags |= 4 }
        return flags
    }
}
