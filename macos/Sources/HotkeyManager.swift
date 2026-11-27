import Carbon.HIToolbox
import Foundation

/// Registry used by the C event callback. Carbon's `InstallEventHandler` takes a
/// plain C function pointer, which cannot capture context, so the actions live in
/// a small file-private table keyed by hotkey id. Every access happens on the main
/// thread (hotkey events and registration both run on the main run loop).
private var hotkeyActionRegistry: [UInt32: () -> Void] = [:]

/// C callback for `kEventClassKeyboard` / `kEventHotKeyPressed`.
private func doctkeyHotkeyEventHandler(_ callRef: EventHandlerCallRef?,
                                       _ event: EventRef?,
                                       _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    guard status == noErr else { return OSStatus(eventNotHandledErr) }
    guard let action = hotkeyActionRegistry[hotKeyID.id] else {
        return OSStatus(eventNotHandledErr)
    }
    action()
    return noErr
}

/// Global hotkeys implemented with Carbon `RegisterEventHotKey`.
///
/// Carbon hotkeys do not need Accessibility permission (unlike event taps), which
/// is why they are used here. Registration failures are logged and skipped so a
/// bad entry in the config never takes the app down.
final class HotkeyManager {
    struct Binding {
        let id: UInt32
        let spec: String
        let action: () -> Void
    }

    /// Four-character signature "DKEY".
    private static let signature: OSType = 0x444B4559

    private var handlerRef: EventHandlerRef?
    private var hotkeyRefs: [EventHotKeyRef] = []
    private var isHandlerInstalled = false

    /// Registers all bindings, replacing any previous set. Returns the number of
    /// hotkeys that could actually be registered.
    @discardableResult
    func register(_ bindings: [Binding]) -> Int {
        unregisterAll()
        installEventHandlerIfNeeded()

        var registered = 0
        for binding in bindings {
            guard let parsed = Config.parseHotkey(binding.spec) else {
                NSLog("DoctKey: invalid hotkey spec \"\(binding.spec)\"; skipped")
                continue
            }

            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: binding.id)
            let status = RegisterEventHotKey(parsed.keyCode,
                                             parsed.modifiers,
                                             hotKeyID,
                                             GetApplicationEventTarget(),
                                             0,
                                             &hotKeyRef)
            guard status == noErr, let hotKeyRef else {
                NSLog("DoctKey: RegisterEventHotKey failed for \"\(binding.spec)\" (status \(status))")
                continue
            }
            hotkeyRefs.append(hotKeyRef)
            hotkeyActionRegistry[binding.id] = binding.action
            registered += 1
        }
        return registered
    }

    func unregisterAll() {
        for ref in hotkeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotkeyRefs.removeAll()
        hotkeyActionRegistry.removeAll()
    }

    deinit {
        unregisterAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    private func installEventHandlerIfNeeded() {
        guard !isHandlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         doctkeyHotkeyEventHandler,
                                         1,
                                         &eventType,
                                         nil,
                                         &handlerRef)
        if status == noErr {
            isHandlerInstalled = true
        } else {
            NSLog("DoctKey: InstallEventHandler failed (status \(status))")
        }
    }
}
