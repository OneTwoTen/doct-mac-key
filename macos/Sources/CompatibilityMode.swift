import ApplicationServices
import Carbon
import Cocoa
import CoreGraphics

// Global CGEventTap compatibility mode.
//
// The normal InputMethodKit path only works when macOS registers DoctKey as an
// input source, which on recent macOS requires a properly signed (Developer ID /
// notarized) input method. This file provides a signing-independent fallback:
// a *session* event tap composes Vietnamese directly into whatever application
// has focus, without DoctKey being an input source at all.
//
// How it works:
//  * the tap intercepts keyDown/keyUp events at the head of the session tap
//    chain (needs the user's Accessibility permission);
//  * every printable key is fed to a private Rust engine instance (its own
//    composition state, independent from the InputMethodKit `KeyHandler`);
//  * the engine's JSON op tells us what to do: post the appended/replaced text
//    as synthetic Unicode keyboard events (and backspaces for `replace`), or let
//    the original physical key through, or swallow it;
//  * synthetic events carry a magic `kCGEventSourceUserData` value and are
//    ignored by the callback, so the tap never re-processes its own output.
//
// The pure planning logic (`CompatEditPlan`, `CompatKeyClassifier`,
// `CompatibilityStatusText`) is AppKit-free and covered by macos/Tests.

// MARK: - Pure planning logic (headless-testable)

/// One host-side edit computed from an engine result and `shown` — the text the
/// compatibility tap has already inserted on screen for the current word.
///
/// Direct-mode insertion is the only presentation compatible mode uses: the
/// document already contains the rendered word, so `replace` edits only the
/// trailing part that changed, while `append` only adds the suffix. Fewer
/// synthetic events per keystroke means no visible lag on Backspace.
struct CompatEditPlan: Equatable {
    /// Characters to delete before the caret (one Backspace press each).
    let backspaces: Int
    /// Text to synthesize at the caret.
    let insert: String
    /// Whether the original physical key event must be swallowed.
    let consumesEvent: Bool
    /// Whether the original physical key event must reach the application.
    let passesEventThrough: Bool
    /// What the tap believes is on screen after this edit.
    let newShown: String

    /// Computes the minimal trailing diff in `Character` units (`backspaces` to
    /// delete from `old`, followed by `insert` from `new`) in a single pass.
    private static func diff(_ old: String, _ new: String) -> (backspaces: Int, insert: String) {
        var oldIdx = old.startIndex
        var newIdx = new.startIndex
        while oldIdx < old.endIndex, newIdx < new.endIndex, old[oldIdx] == new[newIdx] {
            oldIdx = old.index(after: oldIdx)
            newIdx = new.index(after: newIdx)
        }
        let backspaces = old[oldIdx...].count
        let insert = newIdx < new.endIndex ? String(new[newIdx...]) : ""
        return (backspaces, insert)
    }

    /// Computes the edit for an engine result. Never traps on odd payloads: an
    /// unexpected empty op simply consumes the key and leaves the screen alone.
    static func plan(for result: KeyResult, shown: String) -> CompatEditPlan {
        switch result.op {
        case .append:
            // The word grew by `text`; insert just the suffix.
            return CompatEditPlan(backspaces: 0,
                                  insert: result.text,
                                  consumesEvent: result.consumed,
                                  passesEventThrough: !result.consumed,
                                  newShown: shown + result.text)

        case .replace:
            // Retype only what changed. Deleting and re-posting the whole word on
            // every keystroke costs two synthetic key events per visible
            // character — that is the visible stutter when pressing Backspace,
            // worst on long words and while holding the key down. Keeping the
            // common prefix turns the usual backspace (one trailing character
            // disappears) into a single Backspace press with no re-insertion.
            //
            // When the engine stops composing (escape restores the literal raw
            // keys) the replacement becomes plain text, so we stop tracking it.
            let (backspaces, insert) = Self.diff(shown, result.word)
            return CompatEditPlan(backspaces: backspaces,
                                  insert: insert,
                                  consumesEvent: result.consumed,
                                  passesEventThrough: !result.consumed,
                                  newShown: result.composing ? result.word : "")

        case .commit:
            // append/replace already wrote the composition into the document, so
            // the visible text is final: only the delimiter (space, return…)
            // needs to reach the application. If the composition was never
            // tracked (e.g. the tap started mid-word), insert the text instead of
            // silently losing the word.
            let needsInsert = shown.isEmpty && !result.text.isEmpty
            return CompatEditPlan(backspaces: 0,
                                  insert: needsInsert ? result.text : "",
                                  consumesEvent: false,
                                  passesEventThrough: true,
                                  newShown: "")

        case .pass:
            return CompatEditPlan(backspaces: 0,
                                  insert: "",
                                  consumesEvent: false,
                                  passesEventThrough: true,
                                  newShown: result.composing ? shown : "")

        case .none, .state:
            // Consumed, but nothing changes on screen.
            return CompatEditPlan(backspaces: 0,
                                  insert: "",
                                  consumesEvent: true,
                                  passesEventThrough: false,
                                  newShown: result.composing ? shown : "")
        }
    }

    /// True when this edit is just a single trailing deletion triggered by the
    /// physical Backspace key: the tap can let the original Backspace event pass
    /// through natively instead of swallowing it and posting synthetic events.
    func canPassThroughPhysicalBackspace(keyCode: UInt16) -> Bool {
        keyCode == KeyCode.backspace && consumesEvent && backspaces == 1 && insert.isEmpty
    }
}

/// Maps macOS virtual key codes to the engine's non-printing key numbers
/// (docs/SPEC.md, doctkey.h: 1 backspace, 2 forward delete, 3 escape, 4 return,
/// 5 tab, 6 caret movement / other command key). `nil` means "printable key":
/// the actual characters must be read from the event.
enum CompatKeyClassifier {
    static func engineKeyCode(for keyCode: UInt16) -> UInt32? {
        switch keyCode {
        case KeyCode.backspace:
            return 1
        case KeyCode.forwardDelete:
            return 2
        case KeyCode.escape:
            return 3
        case KeyCode.returnKey, KeyCode.keypadEnter:
            return 4
        case KeyCode.tab:
            return 5
        case let code where KeyCode.isMovementOrFunctionKey(code):
            return 6
        default:
            return nil
        }
    }

    /// True for keys the engine handles as non-printing commands.
    static func isEngineKey(_ keyCode: UInt16) -> Bool {
        engineKeyCode(for: keyCode) != nil
    }
}

/// Engine configuration for the compatibility tap's private core instance.
enum CompatibilityEngineConfig {
    static func json(mode: String,
                     method: String,
                     toneStyle: String,
                     smartEnglish: Bool) -> String {
        let safeMode = (mode == "en") ? "en" : "vi"
        let safeMethod = (method == "vni") ? "vni" : "telex"
        let safeTone = (toneStyle == "traditional") ? "traditional" : "modern"
        let smart = smartEnglish ? "true" : "false"
        return "{\"mode\":\"\(safeMode)\",\"method\":\"\(safeMethod)\",\"tone_style\":\"\(safeTone)\",\"smart_english\":\(smart)}"
    }
}

// MARK: - Status reporting

/// Snapshot shown by the settings window and the menu bar. Pure value type so
/// the Vietnamese status text can be unit-tested without AppKit or a tap.
struct CompatibilityStatus: Equatable {
    /// The persisted `compat_mode` switch.
    let enabledByUser: Bool
    /// The CGEventTap is installed and enabled right now.
    let running: Bool
    /// `AXIsProcessTrusted()` at the time of the snapshot.
    let permissionGranted: Bool
    /// False in the `--settings`-only process, which never runs the tap itself.
    let runsInCurrentProcess: Bool
    /// Last Vietnamese error message, if any.
    let lastError: String?

    var displayText: String { CompatibilityStatusText.displayText(for: self) }
    var tone: StatusTone { CompatibilityStatusText.tone(for: self) }
}

/// Vietnamese strings + colour mapping for `CompatibilityStatus`. Kept pure and
/// separate from the tap so both the UI and the tests share one source of truth.
enum CompatibilityStatusText {
    static let permissionRequired = """
    Chưa có quyền Accessibility. Bấm “Cấp quyền Accessibility”, bật DoctKey trong \
    System Settings → Privacy & Security → Accessibility, rồi bấm “Kiểm tra lại”.
    """
    static let tapCreationFailed = "Không tạo được CGEventTap — kiểm tra quyền Accessibility rồi thử lại."
    static let engineUnavailable = "Không khởi tạo được lõi xử lý Rust."
    static let runningText = "Đang chạy — gõ tiếng Việt trực tiếp trong ứng dụng đang dùng."
    static let switchedOffText = "Đang tắt."
    static let notRunningText = "Chưa chạy — bấm “Kiểm tra lại” để thử bật lại."
    static let otherProcessText = "Đã bật trong cấu hình. Chế độ tương thích do tiến trình DoctKey chạy nền đảm nhiệm; nếu không thấy hiệu lực, hãy mở lại DoctKey."

    static func displayText(for status: CompatibilityStatus) -> String {
        guard status.enabledByUser else { return switchedOffText }
        guard status.runsInCurrentProcess else { return otherProcessText }
        if status.running {
            if let lastError = status.lastError, !lastError.isEmpty {
                return "Đang chạy (có cảnh báo: \(lastError))"
            }
            return runningText
        }
        if !status.permissionGranted { return permissionRequired }
        if let lastError = status.lastError, !lastError.isEmpty {
            return "Chưa chạy được: \(lastError)"
        }
        return notRunningText
    }

    static func tone(for status: CompatibilityStatus) -> StatusTone {
        guard status.enabledByUser else { return .neutral }
        guard status.runsInCurrentProcess else { return .neutral }
        if status.running {
            return (status.lastError?.isEmpty ?? true) ? .success : .warning
        }
        if !status.permissionGranted || !(status.lastError?.isEmpty ?? true) {
            return .danger
        }
        return .warning
    }
}

// MARK: - Event tap controller

/// Owns the global CGEventTap and a private Rust engine instance. One controller
/// per process, created and owned by `AppDelegate`; every method must be called
/// on the main thread (the tap is added to the main run loop).
final class CompatibilityTapController {
    /// Result of `start()`; the raw cases are logged and tested.
    enum StartResult: Equatable {
        case started
        case alreadyRunning
        case permissionDenied
        case tapCreationFailed
        case engineUnavailable
    }

    /// Magic `kCGEventSourceUserData` written to synthetic events. "DOCTKEY" in
    /// hex; must stay in sync between posting and filtering.
    static let syntheticEventUserData: Int64 = 0x444F43544B4559

    /// The Accessibility pane of System Settings (the exact URL requested by the
    /// product spec; the newer extension URL is a fallback for newer macOS).
    static let accessibilitySettingsURLs = [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
    ]

    // MARK: Test seams
    //
    // The headless test runner has no Accessibility permission (and must never
    // install a real tap), so the trust check and the tap factory are injectable.
    // The app leaves the defaults untouched.

    /// Defaults to `AXIsProcessTrusted()`.
    var accessibilityTrustProvider: () -> Bool = { AXIsProcessTrusted() }
    /// Defaults to `CGEvent.tapCreate(…)` with the documented tap parameters.
    var tapFactory: (CGEventMask, CGEventTapCallBack, UnsafeMutableRawPointer?) -> CFMachPort? = {
        mask, callback, userInfo in
        CGEvent.tapCreate(tap: .cgSessionEventTap,
                          place: .headInsertEventTap,
                          options: .defaultTap,
                          eventsOfInterest: mask,
                          callback: callback,
                          userInfo: userInfo)
    }
    /// Defaults to `IsSecureEventInputEnabled()`.
    var secureInputProbe: () -> Bool = { IsSecureEventInputEnabled() }
    /// Defaults to `CGEvent.tapEnable(tap:enable:)`.
    var tapEnabler: (CFMachPort, Bool) -> Void = { tap, enable in
        CGEvent.tapEnable(tap: tap, enable: enable)
    }

    // MARK: Runtime state

    /// The tap is created and enabled.
    private(set) var isRunning = false
    /// The feature can actually work right now (tap active + permission held).
    var isEnabled: Bool { isRunning && hasAccessibilityPermission }
    /// Last Vietnamese error reported by `start()` / the tap callback.
    private(set) var lastError: String?
    /// Text this tap has inserted into the focused application.
    private(set) var shown: String = ""
    /// Mirror of the engine's `composing` flag (avoids feeding backspace when
    /// there is no composition to delete).
    private(set) var isComposing = false

    private var core: DoctKeyCore?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var syntheticEventSource: CGEventSource?
    private var desiredConfigJSON: String = "{}"
    private var isEnglishMode = false
    /// Key-downs we swallowed, waiting for their matching key-up to swallow too.
    private var pendingKeyUps: [UInt16: Int] = [:]

    /// Registry used by the C callback (the same pattern as HotkeyManager):
    /// the tap's `userInfo` already points at the instance, this is a fallback
    /// for callback invocations where the pointer is unavailable.
    fileprivate static weak var activeInstance: CompatibilityTapController?

    var hasAccessibilityPermission: Bool { accessibilityTrustProvider() }

    // MARK: - Configuration

    /// Propagates the settings that the engine cares about. When the tap is
    /// already running the config is merged into the live engine; any active
    /// composition is dropped first so screen text stays in sync.
    func updateConfig(mode: String,
                      method: String,
                      toneStyle: String,
                      smart: Bool,
                      insertMode: InsertMode) {
        // Compatibility mode always inserts directly into the document; the
        // marked/direct preference of the InputMethodKit path does not apply.
        _ = insertMode
        isEnglishMode = (mode == "en")
        let json = CompatibilityEngineConfig.json(mode: mode,
                                                  method: method,
                                                  toneStyle: toneStyle,
                                                  smartEnglish: smart)
        desiredConfigJSON = json
        if isRunning {
            if isComposing {
                resetComposition()
            }
            core?.setConfig(json)
        }
    }

    // MARK: - Lifecycle

    /// Installs the tap. Never traps and never prompts: without Accessibility
    /// permission it fails with `.permissionDenied` and an explanatory error.
    @discardableResult
    func start() -> StartResult {
        if isRunning {
            return .alreadyRunning
        }
        guard accessibilityTrustProvider() else {
            lastError = CompatibilityStatusText.permissionRequired
            NSLog("DoctKey compatibility: accessibility permission missing; not starting the tap")
            return .permissionDenied
        }

        // Own engine instance: its composition state must never be shared with
        // the InputMethodKit handler (both may be alive at the same time).
        let engine = DoctKeyCore(configJSON: desiredConfigJSON)
        guard engine.isReady else {
            lastError = CompatibilityStatusText.engineUnavailable
            return .engineUnavailable
        }
        core = engine
        shown = ""
        isComposing = false
        pendingKeyUps.removeAll()

        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue))
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = tapFactory(mask, doctkeyCompatibilityTapCallback, userInfo) else {
            core = nil
            lastError = CompatibilityStatusText.tapCreationFailed
            NSLog("DoctKey compatibility: CGEventTapCreate failed")
            return .tapCreationFailed
        }

        eventTap = tap
        syntheticEventSource = CGEventSource(stateID: .privateState)
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tapEnabler(tap, true)
        isRunning = true
        lastError = nil
        CompatibilityTapController.activeInstance = self
        NSLog("DoctKey compatibility: CGEventTap running (session tap, keyDown/keyUp)")
        return .started
    }

    /// Disables and destroys the tap. Safe to call when not running.
    func stop() {
        if let tap = eventTap {
            tapEnabler(tap, false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        syntheticEventSource = nil
        core = nil
        shown = ""
        isComposing = false
        pendingKeyUps.removeAll()
        if isRunning {
            NSLog("DoctKey compatibility: CGEventTap stopped")
        }
        isRunning = false
        if CompatibilityTapController.activeInstance === self {
            CompatibilityTapController.activeInstance = nil
        }
    }

    deinit {
        stop()
    }

    // MARK: - Composition state

    /// Drops the tracked composition without editing the document. Called when
    /// another application becomes active: the word already inserted stays as
    /// plain text, but a later backspace/replace must never edit the newly
    /// focused app.
    func resetComposition() {
        core?.reset()
        shown = ""
        isComposing = false
        pendingKeyUps.removeAll()
    }

    // MARK: - Accessibility

    /// Triggers the system prompt once (macOS shows it at most once per app
    /// signature); returns the current trust state.
    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        return accessibilityTrustProvider()
    }

    /// Opens System Settings → Privacy & Security → Accessibility.
    @discardableResult
    func openAccessibilitySettings() -> Bool {
        for candidate in CompatibilityTapController.accessibilitySettingsURLs {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return true
            }
        }
        return false
    }

    // MARK: - Status

    func status(enabledByUser: Bool, runsInCurrentProcess: Bool = true) -> CompatibilityStatus {
        CompatibilityStatus(enabledByUser: enabledByUser,
                            running: isRunning,
                            permissionGranted: hasAccessibilityPermission,
                            runsInCurrentProcess: runsInCurrentProcess,
                            lastError: lastError)
    }

    // MARK: - Event tap callback plumbing

    fileprivate func processTapEvent(proxy: CGEventTapProxy,
                                     type: CGEventType,
                                     event: CGEvent) -> Unmanaged<CGEvent>? {
        // 1. Never process our own synthetic output.
        if event.getIntegerValueField(.eventSourceUserData) == CompatibilityTapController.syntheticEventUserData {
            return Unmanaged.passUnretained(event)
        }

        // 2. The system disabled the tap (timeout / user input on another tap):
        //    re-enable it and do not let the pseudo-event escape.
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap {
                tapEnabler(tap, true)
                NSLog("DoctKey compatibility: event tap re-enabled after being disabled by the system")
            }
            return nil
        case .keyDown:
            return handleKeyDown(proxy: proxy, event: event)
        case .keyUp:
            return handleKeyUp(event: event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if isComposing {
                resetComposition()
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Key handling

    private func handleKeyDown(proxy: CGEventTapProxy, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let core else { return Unmanaged.passUnretained(event) }
        if isEnglishMode && !isComposing {
            return Unmanaged.passUnretained(event)
        }

        // Password fields / secure input: never touch the event, and forget any
        // composition so a later backspace cannot corrupt the wrong document.
        if secureInputProbe() {
            if isComposing {
                core.reset()
                shown = ""
                isComposing = false
            }
            pendingKeyUps.removeAll()
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        // Command/control/option combinations belong to the application. The
        // current word is already on screen, so only our tracking must be reset.
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            endCompositionKeepingText()
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if isAutorepeat && isComposing {
            // Held Backspace auto-repeat: drop composition tracking and let the
            // native repeat event delete smoothly without synthetic lag.
            if keyCode == KeyCode.backspace {
                resetComposition()
                pendingKeyUps.removeValue(forKey: keyCode)
                return Unmanaged.passUnretained(event)
            }
            // Auto-repeat of a character key while composing must not duplicate the
            // letter (same policy as the InputMethodKit KeyHandler).
            if !CompatKeyClassifier.isEngineKey(keyCode) {
                return nil
            }
        }

        if let engineKey = CompatKeyClassifier.engineKeyCode(for: keyCode) {
            // Backspace with nothing to delete is the application's business.
            if engineKey == 1 && !isComposing {
                return Unmanaged.passUnretained(event)
            }
            return apply(proxy: proxy,
                         result: core.feedKey(engineKey),
                         keyCode: keyCode,
                         isAutorepeat: isAutorepeat,
                         event: event)
        }

        guard let scalar = singleUnicodeScalar(from: event) else {
            // Multi-scalar output (emoji, combining sequence, dead key): finish
            // the composition and let the application insert the original input.
            endCompositionKeepingText()
            return Unmanaged.passUnretained(event)
        }

        let result = core.feedChar(scalar.value, flags: engineFlags(from: flags))
        return apply(proxy: proxy,
                     result: result,
                     keyCode: keyCode,
                     isAutorepeat: isAutorepeat,
                     event: event)
    }

    private func handleKeyUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        if pendingKeyUps.isEmpty {
            return Unmanaged.passUnretained(event)
        }
        if secureInputProbe() {
            pendingKeyUps.removeAll()
            return Unmanaged.passUnretained(event)
        }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        if let count = pendingKeyUps[keyCode], count > 0 {
            if count == 1 {
                pendingKeyUps.removeValue(forKey: keyCode)
            } else {
                pendingKeyUps[keyCode] = count - 1
            }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    /// Applies one engine result to the screen and decides the fate of the
    /// original physical key event.
    private func apply(proxy: CGEventTapProxy,
                       result: KeyResult,
                       keyCode: UInt16,
                       isAutorepeat: Bool,
                       event: CGEvent) -> Unmanaged<CGEvent>? {
        let plan = CompatEditPlan.plan(for: result, shown: shown)
        if plan.canPassThroughPhysicalBackspace(keyCode: keyCode) {
            shown = plan.newShown
            isComposing = result.composing
            return Unmanaged.passUnretained(event)
        }
        if plan.backspaces > 0 {
            postBackspaces(plan.backspaces, proxy: proxy)
        }
        if !plan.insert.isEmpty {
            postUnicodeText(plan.insert, proxy: proxy)
        }
        shown = plan.newShown
        isComposing = result.composing

        if plan.consumesEvent {
            if !isAutorepeat {
                pendingKeyUps[keyCode, default: 0] += 1
            }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    /// Ends the tracked composition without changing the screen: append/replace
    /// already wrote the final text, so committing the engine is enough.
    private func endCompositionKeepingText() {
        guard isComposing else {
            shown = ""
            return
        }
        _ = core?.commit()
        shown = ""
        isComposing = false
    }

    // MARK: - Event field helpers

    /// Extracts exactly one printable Unicode scalar from a keyboard event.
    /// Returns nil for control characters, dead keys and multi-scalar output
    /// (the caller then passes the original event through untouched).
    private func singleUnicodeScalar(from event: CGEvent) -> Unicode.Scalar? {
        var length = 0
        var pair: (UniChar, UniChar) = (0, 0)
        withUnsafeMutablePointer(to: &pair) { ptr in
            ptr.withMemoryRebound(to: UniChar.self, capacity: 2) { buffer in
                event.keyboardGetUnicodeString(maxStringLength: 2,
                                               actualStringLength: &length,
                                               unicodeString: buffer)
            }
        }
        guard length == 1, let scalar = Unicode.Scalar(pair.0) else { return nil }
        guard scalar.value >= 0x20, scalar.value != 0x7F else { return nil }
        return scalar
    }

    /// Engine flag bits (doctkey.h): bit0 shift, bit1 caps lock, bit2 option.
    private func engineFlags(from flags: CGEventFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.maskShift) { result |= 1 }
        if flags.contains(.maskAlphaShift) { result |= 2 }
        if flags.contains(.maskAlternate) { result |= 4 }
        return result
    }

    // MARK: - Synthetic event posting

    private func postUnicodeText(_ text: String, proxy: CGEventTapProxy) {
        let count = text.utf16.count
        guard count > 0 else { return }
        withUnsafeTemporaryAllocation(of: UniChar.self, capacity: count) { buffer in
            var index = 0
            for unit in text.utf16 {
                buffer[index] = unit
                index += 1
            }
            if let downEvent = CGEvent(keyboardEventSource: syntheticEventSource, virtualKey: 0, keyDown: true) {
                downEvent.flags = []
                downEvent.keyboardSetUnicodeString(stringLength: count,
                                                   unicodeString: buffer.baseAddress)
                downEvent.setIntegerValueField(.eventSourceUserData,
                                               value: CompatibilityTapController.syntheticEventUserData)
                downEvent.tapPostEvent(proxy)
            }
        }
        // The key-up carries no Unicode string: the insertion happens on key-down.
        if let upEvent = CGEvent(keyboardEventSource: syntheticEventSource, virtualKey: 0, keyDown: false) {
            upEvent.flags = []
            upEvent.setIntegerValueField(.eventSourceUserData,
                                         value: CompatibilityTapController.syntheticEventUserData)
            upEvent.tapPostEvent(proxy)
        }
    }

    private func postBackspaces(_ count: Int, proxy: CGEventTapProxy) {
        guard count > 0 else { return }
        for _ in 0..<count {
            postVirtualKey(KeyCode.backspace, proxy: proxy)
        }
    }

    private func postVirtualKey(_ keyCode: CGKeyCode, proxy: CGEventTapProxy) {
        postVirtualKeyEvent(keyCode, keyDown: true, proxy: proxy)
        postVirtualKeyEvent(keyCode, keyDown: false, proxy: proxy)
    }

    private func postVirtualKeyEvent(_ keyCode: CGKeyCode, keyDown: Bool, proxy: CGEventTapProxy) {
        guard let event = CGEvent(keyboardEventSource: syntheticEventSource, virtualKey: keyCode, keyDown: keyDown) else {
            return
        }
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData,
                                   value: CompatibilityTapController.syntheticEventUserData)
        event.tapPostEvent(proxy)
    }
}

// MARK: - C callback

/// CGEventTap callback (a plain C function pointer, so it cannot capture
/// context). The controller is reached through the tap's `userInfo` pointer, with
/// a global registry fallback.
private func doctkeyCompatibilityTapCallback(_ proxy: CGEventTapProxy,
                                             _ type: CGEventType,
                                             _ event: CGEvent,
                                             _ userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let controller: CompatibilityTapController?
    if let userInfo {
        controller = Unmanaged<CompatibilityTapController>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
    } else {
        controller = CompatibilityTapController.activeInstance
    }
    guard let controller else {
        return Unmanaged.passUnretained(event)
    }
    return controller.processTapEvent(proxy: proxy, type: type, event: event)
}
