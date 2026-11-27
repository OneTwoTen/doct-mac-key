import Cocoa
import InputMethodKit

/// Bridges an `IMKTextInput` client to the host-agnostic `TextHost` protocol.
/// All text replacement happens through `insertText(_:replacementRange:)`, which
/// is the InputMethodKit way of editing the document.
private final class IMKTextHost: TextHost {
    private weak var client: IMKTextInput?

    init(client: IMKTextInput) {
        self.client = client
    }

    func insertText(_ text: String) {
        client?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func replaceTrailing(_ utf16Length: Int, with text: String) {
        guard let client else { return }
        let selection = client.selectedRange()
        guard selection.location != NSNotFound else {
            // No selection information: fall back to plain insertion instead of
            // computing a negative range.
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }
        let start = max(0, selection.location - max(0, utf16Length))
        let length = selection.location - start
        client.insertText(text, replacementRange: NSRange(location: start, length: length))
    }

    func setMarkedText(_ text: String) {
        let selection = NSRange(location: text.utf16.count, length: 0)
        client?.setMarkedText(text,
                              selectionRange: selection,
                              replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func commitMarkedText(with text: String) {
        // With marked text present, insertText replaces it; without it, this is a
        // plain insertion at the caret.
        client?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}

/// The InputMethodKit controller. It converts `NSEvent`s into `KeyInput`s, keeps
/// one `IMKTextHost` for the active client and delegates all linguistic work to
/// the shared `KeyHandler`.
///
/// The class name is exposed to Objective-C as `DoctKeyInputController` because
/// `Info.plist` points `InputMethodServerControllerClass` at that name.
@objc(DoctKeyInputController)
final class InputController: IMKInputController {
    private var hostAdapter: IMKTextHost?
    private weak var activeClient: IMKTextInput?

    // MARK: - IMKInputController

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        guard let keyHandler = AppDelegate.shared?.keyHandler else { return false }

        if let client = sender as? IMKTextInput, client !== activeClient {
            attach(client: client, keyHandler: keyHandler)
        }

        let input = KeyInput(characters: event.characters,
                             keyCode: event.keyCode,
                             modifiers: InputController.modifiers(from: event.modifierFlags),
                             isRepeat: event.isARepeat)
        // `true` means "swallow the key"; `false` lets the application handle it.
        return keyHandler.handle(input)
    }

    override func activateServer(_ sender: Any!) {
        if let client = sender as? IMKTextInput, let keyHandler = AppDelegate.shared?.keyHandler {
            attach(client: client, keyHandler: keyHandler)
        }
        super.activateServer(sender)
    }

    override func deactivateServer(_ sender: Any!) {
        if let keyHandler = AppDelegate.shared?.keyHandler {
            // Focus loss: commit whatever is being composed so the user does not
            // lose the word.
            keyHandler.commitComposition()
            if let hostAdapter {
                keyHandler.detach(host: hostAdapter)
            }
        }
        hostAdapter = nil
        activeClient = nil
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        AppDelegate.shared?.keyHandler.commitComposition()
    }

    // MARK: - Client attachment

    private func attach(client: IMKTextInput, keyHandler: KeyHandler) {
        if activeClient !== client {
            // Switching clients without a deactivate: finish the old composition
            // in the old client before adopting the new one.
            if let hostAdapter {
                keyHandler.commitComposition()
                keyHandler.detach(host: hostAdapter)
            }
            let adapter = IMKTextHost(client: client)
            keyHandler.attach(host: adapter)
            hostAdapter = adapter
            activeClient = client
        }
    }

    // MARK: - Event conversion

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.capsLock) { modifiers.insert(.capsLock) }
        if flags.contains(.function) { modifiers.insert(.function) }
        return modifiers
    }
}
