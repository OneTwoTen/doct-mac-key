import Foundation

// DoctKey Swift test runner.
//
// 1. Runs every `core/tests/fixtures/*.tsv` case through the real `KeyHandler` +
//    engine, in both insert modes (marked and direct), with a faithful mock host,
//    and compares the resulting document text with the expected column.
// 2. Runs additional unit checks for host-level behaviour (hotkeys, toggles,
//    EN passthrough, backspace, auto-repeat, insert-mode switching, config I/O).
//
// Exit code 0 only when everything passes.

// MARK: - Repository layout

func findRepositoryRoot() -> String {
    let current = FileManager.default.currentDirectoryPath
    if FileManager.default.fileExists(atPath: current + "/core/tests/fixtures") {
        return current
    }
    // Fall back to the location of this source file: <root>/macos/Tests/main.swift
    let testsDirectory = (#filePath as NSString).deletingLastPathComponent
    let macosDirectory = (testsDirectory as NSString).deletingLastPathComponent
    return (macosDirectory as NSString).deletingLastPathComponent
}

// MARK: - Fixture parsing

struct FixtureCase {
    let file: String
    let lineNumber: Int
    let method: String
    let mode: String
    let smart: Bool
    let toneStyle: String
    let keys: String
    let expected: String
}

func listFixtureFiles(in directory: String) -> [String] {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
        return []
    }
    return entries.filter { $0.hasSuffix(".tsv") }.sorted()
}

func parseFixtures(file: String, path: String) -> [FixtureCase] {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("warning: could not read \(path)")
        return []
    }
    var cases: [FixtureCase] = []
    for (offset, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        let columns = rawLine.components(separatedBy: "\t")
        guard columns.count >= 3 else {
            print("warning: \(file):\(offset + 1): expected 3 TSV columns, got \(columns.count)")
            continue
        }
        let meta = columns[0].split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        guard meta.count >= 4 else {
            print("warning: \(file):\(offset + 1): bad fixture header column \"\(columns[0])\"")
            continue
        }
        cases.append(FixtureCase(file: file,
                                 lineNumber: offset + 1,
                                 method: meta[0].lowercased(),
                                 mode: meta[1].lowercased(),
                                 smart: meta[2] == "1" || meta[2].lowercased() == "true",
                                 toneStyle: meta[3].lowercased(),
                                 keys: columns[1],
                                 expected: columns[2...].joined(separator: "\t")))
    }
    return cases
}

// MARK: - Key sequence tokenizer (same syntax as core/src/sim.rs)

func specialKey(for token: String) -> KeyInput? {
    switch token {
    case "BS": return KeyInput(keyCode: KeyCode.backspace)
    case "DEL": return KeyInput(keyCode: KeyCode.forwardDelete)
    case "ESC": return KeyInput(keyCode: KeyCode.escape)
    case "ENTER": return KeyInput(keyCode: KeyCode.returnKey)
    case "TAB": return KeyInput(keyCode: KeyCode.tab)
    case "HOME": return KeyInput(keyCode: KeyCode.home)
    case "END": return KeyInput(keyCode: KeyCode.end)
    case "PAGEUP": return KeyInput(keyCode: KeyCode.pageUp)
    case "PAGEDOWN": return KeyInput(keyCode: KeyCode.pageDown)
    case "LEFT": return KeyInput(keyCode: KeyCode.leftArrow)
    case "RIGHT": return KeyInput(keyCode: KeyCode.rightArrow)
    case "UP": return KeyInput(keyCode: KeyCode.upArrow)
    case "DOWN": return KeyInput(keyCode: KeyCode.downArrow)
    default: return nil
    }
}

func keyInputs(from keys: String) -> [KeyInput] {
    var inputs: [KeyInput] = []
    var index = keys.startIndex
    while index < keys.endIndex {
        let character = keys[index]
        if character == "<", let closing = keys[index...].firstIndex(of: ">") {
            let token = String(keys[keys.index(after: index)..<closing]).uppercased()
            if let mapped = specialKey(for: token) {
                inputs.append(mapped)
            } else {
                // Unknown <...> token: treat every character literally.
                for literal in keys[index...closing] {
                    inputs.append(KeyInput(characters: String(literal)))
                }
            }
            index = keys.index(after: closing)
            continue
        }
        inputs.append(KeyInput(characters: String(character)))
        index = keys.index(after: index)
    }
    return inputs
}

// MARK: - Driving a handler against the mock host

/// What the application does with a key the IME did not consume.
func applyToHost(_ input: KeyInput, host: MockHost) {
    switch input.keyCode {
    case KeyCode.backspace:
        host.deleteBackward()
    case KeyCode.returnKey, KeyCode.keypadEnter:
        host.insertText("\n")
    case KeyCode.tab:
        host.insertText("\t")
    case KeyCode.escape, KeyCode.forwardDelete:
        break // no effect on the document
    default:
        if let characters = input.characters, !characters.isEmpty {
            host.insertText(characters)
        }
    }
}

/// Feeds a fixture-style key string through the handler, letting the mock host
/// process any key the IME passes through (exactly like the real app does).
func drive(_ keys: String, handler: KeyHandler, host: MockHost) {
    for input in keyInputs(from: keys) {
        let consumed = handler.handle(input)
        if !consumed {
            applyToHost(input, host: host)
        }
    }
}

func makeEngineConfigJSON(_ fixture: FixtureCase) -> String? {
    let object: [String: Any] = [
        "mode": fixture.mode,
        "method": fixture.method,
        "tone_style": fixture.toneStyle,
        "smart_english": fixture.smart
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    return String(data: data, encoding: .utf8)
}

/// Returns nil on success, or a failure description.
func runFixture(_ fixture: FixtureCase, insertMode: InsertMode) -> String? {
    guard let configJSON = makeEngineConfigJSON(fixture) else {
        return "could not encode fixture config"
    }
    let core = DoctKeyCore(configJSON: configJSON)
    guard core.isReady else { return "engine could not be created" }

    // Fresh engine + handler per fixture: the engine keeps global (per-instance)
    // mode state, so state must never leak between cases.
    let handler = KeyHandler(core: core, insertMode: insertMode)
    let host = MockHost()
    handler.attach(host: host)

    drive(fixture.keys, handler: handler, host: host)
    handler.commitComposition()

    guard host.documentText == fixture.expected else {
        return "expected \"\(fixture.expected)\" got \"\(host.documentText)\""
    }
    return nil
}

// MARK: - Compatibility-mode reference host
//
// Replays the same fixtures through the exact decision pipeline the CGEventTap
// uses — engine result -> `CompatEditPlan` -> screen edits — with a plain string
// as the document instead of real synthetic CGEvents. This proves the pure
// planning logic composes Vietnamese correctly without needing Accessibility
// permission or an installed event tap.

/// What the focused application does with a key the tap let through (the same
/// rules as `applyToHost`, against a plain document string).
func applyToDocument(_ input: KeyInput, document: inout String) {
    switch input.keyCode {
    case KeyCode.backspace:
        if !document.isEmpty { document.removeLast() }
    case KeyCode.returnKey, KeyCode.keypadEnter:
        document += "\n"
    case KeyCode.tab:
        document += "\t"
    case KeyCode.escape, KeyCode.forwardDelete:
        break
    default:
        if let characters = input.characters, !characters.isEmpty {
            document += characters
        }
    }
}

/// Returns nil on success, or a failure description.
func runCompatibilityFixture(_ fixture: FixtureCase) -> String? {
    guard let configJSON = makeEngineConfigJSON(fixture) else {
        return "could not encode fixture config"
    }
    let core = DoctKeyCore(configJSON: configJSON)
    guard core.isReady else { return "engine could not be created" }

    var document = ""
    var shown = ""
    var composing = false

    /// Applies one engine result exactly like `CompatibilityTapController.apply`.
    func applyResult(_ result: KeyResult) {
        let plan = CompatEditPlan.plan(for: result, shown: shown)
        if plan.backspaces > 0 {
            let removable = min(plan.backspaces, document.count)
            if removable > 0 { document.removeLast(removable) }
        }
        document += plan.insert
        shown = plan.newShown
        composing = result.composing
    }

    for input in keyInputs(from: fixture.keys) {
        // Command/control/option combinations always belong to the application.
        if input.modifiers.contains(.command)
            || input.modifiers.contains(.control)
            || input.modifiers.contains(.option) {
            if composing {
                applyResult(core.commit())
                composing = false
            }
            applyToDocument(input, document: &document)
            continue
        }

        // Backspace with no composition is passed straight to the application.
        if input.keyCode == KeyCode.backspace && !composing {
            applyToDocument(input, document: &document)
            continue
        }

        if let engineKey = CompatKeyClassifier.engineKeyCode(for: input.keyCode) {
            let result = core.feedKey(engineKey)
            let plan = CompatEditPlan.plan(for: result, shown: shown)
            applyResult(result)
            if plan.passesEventThrough { applyToDocument(input, document: &document) }
            continue
        }

        guard let characters = input.characters,
              characters.unicodeScalars.count == 1,
              let scalar = characters.unicodeScalars.first,
              scalar.value >= 0x20,
              scalar.value != 0x7F else {
            if composing {
                applyResult(core.commit())
                composing = false
            }
            applyToDocument(input, document: &document)
            continue
        }
        var flags: UInt32 = 0
        if input.modifiers.contains(.shift) { flags |= 1 }
        if input.modifiers.contains(.capsLock) { flags |= 2 }
        let result = core.feedChar(scalar.value, flags: flags)
        let plan = CompatEditPlan.plan(for: result, shown: shown)
        applyResult(result)
        // `pass`/`commit` let the original key through (commit consumed == false).
        if plan.consumesEvent == false { applyToDocument(input, document: &document) }
    }

    // End of input: the tap would commit any open composition on teardown; the
    // text is already in the document, so this only resets tracking.
    applyResult(core.commit())

    guard document == fixture.expected else {
        return "expected \"\(fixture.expected)\" got \"\(document)\""
    }
    return nil
}

// MARK: - Extra unit checks

var extraPassed = 0
var extraFailed = 0

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        extraPassed += 1
    } else {
        extraFailed += 1
        print("  FAIL [extra] \(name) \(detail())")
    }
}

// MARK: - Run

let repositoryRoot = findRepositoryRoot()
let fixturesDirectory = repositoryRoot + "/core/tests/fixtures"

print("DoctKey Swift fixture runner")
print("repository: \(repositoryRoot)")

let fixtureFiles = listFixtureFiles(in: fixturesDirectory)
guard !fixtureFiles.isEmpty else {
    print("error: no .tsv fixtures found in \(fixturesDirectory)")
    exit(2)
}

var totalRuns = 0
var passedRuns = 0
var failures: [String] = []

var totalCompatibilityRuns = 0
var passedCompatibilityRuns = 0
var compatibilityFailures: [String] = []

print("windows: \(fixtureFiles.joined(separator: ", "))")
print("")
for file in fixtureFiles {
    let cases = parseFixtures(file: file, path: fixturesDirectory + "/" + file)
    guard !cases.isEmpty else {
        print("warning: \(file) has no fixture cases")
        continue
    }
    for insertMode in InsertMode.allCases {
        var modePassed = 0
        for fixture in cases {
            totalRuns += 1
            if let failure = runFixture(fixture, insertMode: insertMode) {
                failures.append("[\(insertMode.rawValue)] \(file):\(fixture.lineNumber) keys=\(fixture.keys): \(failure)")
            } else {
                modePassed += 1
                passedRuns += 1
            }
        }
        print("  [\(insertMode.rawValue)] \(file): \(modePassed)/\(cases.count)")
    }
    // Same fixtures through the CGEventTap decision pipeline (compat mode).
    var compatibilityPassed = 0
    for fixture in cases {
        totalCompatibilityRuns += 1
        if let failure = runCompatibilityFixture(fixture) {
            compatibilityFailures.append("\(file):\(fixture.lineNumber) keys=\(fixture.keys): \(failure)")
        } else {
            compatibilityPassed += 1
            passedCompatibilityRuns += 1
        }
    }
    print("  [compat] \(file): \(compatibilityPassed)/\(cases.count)")
}

print("")
if !failures.isEmpty || !compatibilityFailures.isEmpty {
    print("FAILURES:")
    for failure in failures {
        print("  - \(failure)")
    }
    for failure in compatibilityFailures {
        print("  - [compat] \(failure)")
    }
    print("")
}

// MARK: - Extra checks

do {
    let defaults = Config.defaultHotkeys
    check("default hotkey count", defaults.count == 5, "count=\(defaults.count)")
    check("default toggle_mode", defaults["toggle_mode"] == "ctrl+alt+v")
    check("default toggle_method", defaults["toggle_method"] == "ctrl+alt+t")
    check("default toggle_tone_style", defaults["toggle_tone_style"] == "ctrl+alt+d")
    check("default toggle_smart", defaults["toggle_smart"] == "ctrl+alt+e")
    check("default reload_config", defaults["reload_config"] == "ctrl+alt+r")

    let expected = ParsedHotkey(keyCode: 0x09,
                                modifiers: ParsedHotkey.controlMask | ParsedHotkey.optionMask)
    check("hotkey parse ctrl+alt+v", Config.parseHotkey("ctrl+alt+v") == expected)
    check("hotkey parse is case-insensitive",
          Config.parseHotkey("Control+Option+V") == expected)
    check("hotkey parse accepts command modifier",
          Config.parseHotkey("cmd+shift+v") == ParsedHotkey(keyCode: 0x09,
                                                           modifiers: ParsedHotkey.commandMask | ParsedHotkey.shiftMask))
    check("hotkey parse rejects empty spec", Config.parseHotkey("") == nil)
    check("hotkey parse rejects unknown modifier", Config.parseHotkey("hyper+v") == nil)
    check("hotkey parse rejects missing key", Config.parseHotkey("ctrl+alt") == nil)
    check("hotkey parse rejects dangling separator", Config.parseHotkey("ctrl+alt+") == nil)
}

do {
    // Mode change must not lose a half-typed word: it commits the composition.
    let core = DoctKeyCore(configJSON: #"{"mode":"vi","method":"telex","tone_style":"modern","smart_english":true}"#)
    let handler = KeyHandler(core: core, insertMode: .marked)
    let host = MockHost()
    handler.attach(host: host)
    drive("vieejt", handler: handler, host: host)
    let result = handler.command(#"{"cmd":"toggle_mode"}"#)
    // KeyHandler.command commits an open word before running any command, so the
    // command itself reports a state update rather than a commit.
    check("toggle_mode keeps the committed text", host.documentText == "việt", "doc=\(host.documentText)")
    check("toggle_mode leaves no marked text", host.markedRange == nil)
    check("toggle_mode switches engine to EN", core.status().mode == "en", "mode=\(core.status().mode)")
    check("toggle_mode reports a state result", result.op == .state || result.op == .commit, "op=\(result.op.rawValue)")
}

do {
    // Toggling tone style / smart mid-word must commit the word first: the host
    // text and the engine state may never desynchronise (regression test for a
    // direct-mode document-corruption bug).
    let core = DoctKeyCore(configJSON: #"{"mode":"vi","method":"telex","tone_style":"modern","smart_english":true}"#)
    let handler = KeyHandler(core: core, insertMode: .direct)
    let host = MockHost()
    handler.attach(host: host)
    drive("looks", handler: handler, host: host)
    check("direct: smart-escaped word is visible", host.documentText == "looks", "doc=\(host.documentText)")
    _ = handler.command(#"{"cmd":"toggle_smart"}"#)
    check("toggle_smart commits the composition first", host.documentText == "looks", "doc=\(host.documentText)")
    check("toggle_smart resets engine composition", core.status().composing == false)
    _ = handler.handle(KeyInput(characters: "n"))
    check("typing after toggle_smart starts a fresh word", host.documentText == "looksn", "doc=\(host.documentText)")
}

do {
    // Marked mode: a tone-style toggle mid-word commits the current spelling.
    let core = DoctKeyCore(configJSON: #"{"mode":"vi","method":"telex","tone_style":"modern"}"#)
    let handler = KeyHandler(core: core, insertMode: .marked)
    let host = MockHost()
    handler.attach(host: host)
    drive("hoas", handler: handler, host: host)
    check("marked: sắc spelling shown", host.documentText == "hoá", "doc=\(host.documentText)")
    _ = handler.command(#"{"cmd":"toggle_tone_style"}"#)
    check("toggle_tone_style commits marked text", host.documentText == "hoá", "doc=\(host.documentText)")
    check("toggle_tone_style leaves no marked text", host.markedRange == nil)
}

do {
    // EN mode: every printable key is passed through untouched.
    let core = DoctKeyCore(configJSON: #"{"mode":"en","method":"telex"}"#)
    let handler = KeyHandler(core: core, insertMode: .direct)
    let host = MockHost()
    handler.attach(host: host)
    var allPassedThrough = true
    for character in "as" {
        let consumed = handler.handle(KeyInput(characters: String(character)))
        if consumed {
            allPassedThrough = false
        } else {
            host.insertText(String(character))
        }
    }
    handler.commitComposition()
    check("EN mode passes printable keys through", allPassedThrough)
    check("EN mode document unchanged by the engine", host.documentText == "as", "doc=\(host.documentText)")
}

do {
    // Backspace with no composition: pass through, do not edit anything.
    let core = DoctKeyCore(configJSON: #"{"mode":"vi","method":"telex"}"#)
    let handler = KeyHandler(core: core, insertMode: .direct)
    let host = MockHost()
    handler.attach(host: host)
    let consumed = handler.handle(KeyInput(keyCode: KeyCode.backspace))
    check("backspace with empty composition is passed through", consumed == false)
    check("backspace with empty composition leaves document empty", host.documentText == "", "doc=\(host.documentText)")
}

do {
    // Auto-repeat of a character key while composing must be swallowed.
    let core = DoctKeyCore(configJSON: #"{"mode":"vi","method":"telex"}"#)
    let handler = KeyHandler(core: core, insertMode: .direct)
    let host = MockHost()
    handler.attach(host: host)
    _ = handler.handle(KeyInput(characters: "a"))
    let beforeRepeat = host.documentText
    let repeatConsumed = handler.handle(KeyInput(characters: "s", isRepeat: true))
    check("auto-repeat character is swallowed while composing", repeatConsumed)
    check("auto-repeat does not change the document", host.documentText == beforeRepeat, "doc=\(host.documentText)")
    handler.commitComposition()
    check("composition commits correctly after swallowed repeat", host.documentText == "a", "doc=\(host.documentText)")
}

do {
    // Escape inside a marked composition: literal keystrokes restored as plain text.
    let core = DoctKeyCore(configJSON: #"{"mode":"vi","method":"telex"}"#)
    let handler = KeyHandler(core: core, insertMode: .marked)
    let host = MockHost()
    handler.attach(host: host)
    drive("as", handler: handler, host: host)
    _ = handler.handle(KeyInput(keyCode: KeyCode.escape))
    check("escape restores the literal keystrokes", host.documentText == "as", "doc=\(host.documentText)")
    check("escape clears marked text", host.markedRange == nil)
    handler.commitComposition()
    check("escape keeps plain text on commit", host.documentText == "as", "doc=\(host.documentText)")
}

do {
    // Switching insert mode mid-word commits instead of dropping the word.
    let core = DoctKeyCore(configJSON: #"{"mode":"vi","method":"telex"}"#)
    let handler = KeyHandler(core: core, insertMode: .direct)
    let host = MockHost()
    handler.attach(host: host)
    drive("vieejt", handler: handler, host: host)
    handler.setInsertMode(.marked)
    check("insert-mode switch commits the composition", host.documentText == "việt", "doc=\(host.documentText)")
    check("insert-mode switch updates the mode", handler.insertMode == .marked)
}

do {
    // Command/control/option combos belong to the application.
    let core = DoctKeyCore(configJSON: #"{"mode":"vi","method":"telex"}"#)
    let handler = KeyHandler(core: core, insertMode: .direct)
    let host = MockHost()
    handler.attach(host: host)
    _ = handler.handle(KeyInput(characters: "a"))
    let consumed = handler.handle(KeyInput(characters: "c", modifiers: [.command]))
    check("command combos are passed through", consumed == false)
    check("command combos commit the composition", host.documentText == "a", "doc=\(host.documentText)")
}

do {
    // Result decoding never traps on malformed payloads.
    check("garbage result JSON decodes safely", KeyResult.decode("not json").op == .none)
    check("unknown op decodes to none", KeyResult.decode(#"{"op":"weird"}"#).op == .none)
    let decoded = KeyResult.decode(#"{"op":"append","text":"á","word":"á","composing":true,"consumed":true,"mode":"vi","method":"telex","tone_style":"modern","smart":true}"#)
    check("result JSON decodes append", decoded.op == .append)
    check("result JSON decodes text", decoded.text == "á", "text=\(decoded.text)")
    check("result JSON decodes composing", decoded.composing)
}

do {
    // Config round trip + defaults file creation.
    let temporaryPath = NSTemporaryDirectory() + "doctkey-config-test-\(UUID().uuidString).json"
    let config = Config(path: temporaryPath)
    check("config creates defaults when missing", FileManager.default.fileExists(atPath: temporaryPath))
    check("default config mode is vi", config.mode == "vi")
    check("default config method is telex", config.method == "telex")
    check("default config insert mode is marked", config.insertMode == .marked)
    check("default config smart english is on", config.smartEnglish)
    check("engine config JSON is not empty", config.engineJSON.contains("telex"), "json=\(config.engineJSON)")

    config.mode = "en"
    config.method = "vni"
    config.toneStyle = "traditional"
    config.smartEnglish = false
    config.insertMode = .direct
    config.save()

    let reloaded = Config(path: temporaryPath)
    check("config round-trips mode", reloaded.mode == "en", "mode=\(reloaded.mode)")
    check("config round-trips method", reloaded.method == "vni", "method=\(reloaded.method)")
    check("config round-trips tone style", reloaded.toneStyle == "traditional")
    check("config round-trips insert mode", reloaded.insertMode == .direct)
    check("config round-trips smart english", reloaded.smartEnglish == false)
    check("config keeps default hotkeys", reloaded.hotkeys["toggle_mode"] == "ctrl+alt+v")
    try? FileManager.default.removeItem(atPath: temporaryPath)
}

do {
    // Invalid config JSON: graceful defaults, no crash, file left untouched.
    let temporaryPath = NSTemporaryDirectory() + "doctkey-config-bad-\(UUID().uuidString).json"
    try? "{ this is not json".write(toFile: temporaryPath, atomically: true, encoding: .utf8)
    let config = Config(path: temporaryPath)
    check("invalid config falls back to defaults", config.mode == "vi" && config.method == "telex")
    let contents = try? String(contentsOfFile: temporaryPath, encoding: .utf8)
    check("invalid config is left untouched on load", contents == "{ this is not json")
    try? FileManager.default.removeItem(atPath: temporaryPath)
}

// MARK: - Settings / management helpers (headless checks)

do {
    // Input-source state mapping.
    check("status: not registered", InputSourceState.from(sourceCount: 0, enabledCount: 0) == .notRegistered)
    check("status: registered disabled", InputSourceState.from(sourceCount: 2, enabledCount: 0) == .registeredDisabled)
    check("status: registered enabled", InputSourceState.from(sourceCount: 2, enabledCount: 1) == .registeredAndEnabled)
    check("status: summary counts sources",
          SettingsStatusText.sourceSummary(sourceCount: 2, enabledCount: 1, selectedCount: 0).contains("2 nguồn"))
    check("status: not-registered hint mentions logout",
          SettingsStatusText.hint(for: .notRegistered).lowercased().contains("đăng xuất"))
    check("status: installed hint names path",
          SettingsStatusText.installSuccessHint(path: "/Library/Input Library/DoctKey.app").contains("/Library/Input Library/DoctKey.app"))

    // Install location rules per macOS version.
    let mac26 = AppInstallation.target(majorOSVersion: 26, home: "/Users/tester")
    check("install: macOS 26 targets system Input Methods",
          mac26.directory == "/Library/Input Methods" && mac26.requiresAdministrator)
    let mac14 = AppInstallation.target(majorOSVersion: 14, home: "/Users/tester")
    check("install: older macOS targets user dir",
          mac14.bundlePath == "/Users/tester/Library/Input Methods/DoctKey.app" && !mac14.requiresAdministrator)
    check("install: repo build detection",
          AppInstallation.isRepositoryBuild(path: "/repo/build/DoctKey.app")
          && !AppInstallation.isRepositoryBuild(path: AppInstallation.systemBundlePath()))
    check("install: nothing installed when files absent",
          AppInstallation.installedBundlePath(home: "/Users/tester") { _ in false } == nil)
    check("install: system copy has priority",
          AppInstallation.installedBundlePath(home: "/Users/tester") { $0 == AppInstallation.systemBundlePath() }
              == AppInstallation.systemBundlePath())

    // Privileged installer command construction.
    check("installer: shell quote wraps spaces",
          PrivilegedInstaller.shellQuote("/Library/Input Library") == "'/Library/Input Library'")
    check("installer: shell quote escapes single quotes",
          PrivilegedInstaller.shellQuote("it's") == "'it'\\''s'")
    check("installer: administrator script requests privileges",
          PrivilegedInstaller.administratorScript(forShellCommands: ["true"])
              .contains("with administrator privileges"))
    check("installer: system target chowns root wheel",
          PrivilegedInstaller.installCommands(sourceBundle: "/tmp/DoctKey.app", target: mac26)
              .contains { $0.contains("chown -R root:wheel") })
    check("installer: cancel is not a failure",
          PrivilegedInstaller.isUserCancellation(exitCode: 1, stderr: "execution error: User canceled. (-128)"))
    check("installer: success is not a cancellation",
          !PrivilegedInstaller.isUserCancellation(exitCode: 0, stderr: ""))

    // Signing helpers.
    let identities = SigningIdentityParser.parse("""
      1) ABCDEF1234567890 "Apple Development: Tester (TEAMID)"
         1 valid identities found
      """)
    check("signing: identity parsed",
          identities.count == 1 && identities.first?.sha1 == "ABCDEF1234567890" && identities.first?.isValid == true)
    check("signing: empty identity list summarized",
          SigningIdentityParser.summary([]).contains("ad-hoc"))
    let adhoc = SignatureDescription.parse("Identifier=com.doct.doctkey\nSignature=adhoc\nTeamIdentifier=not set")
    check("signing: ad-hoc parsed", adhoc.isAdHoc && adhoc.teamIdentifier == nil)
    let developerID = SignatureDescription.parse("Authority=Developer ID Application: Someone (TEAM)\nTeamIdentifier=TEAM123")
    check("signing: developer id parsed", !developerID.isAdHoc && developerID.teamIdentifier == "TEAM123")

    // Launch heuristics: never pop a window when InputMethodKit starts the app.
    let settingsLaunch = LaunchContext(arguments: ["/x/DoctKey", "--settings"],
                                       forceSettings: true,
                                       parentProcessPaths: [])
    check("launch: --settings shows immediately", settingsLaunch.launchDecision == .showImmediately)
    let imkLaunch = LaunchContext(arguments: ["/x/DoctKey"],
                                  forceSettings: false,
                                  parentProcessPaths: ["/System/Library/Frameworks/InputMethodKit.framework/Resources/imklaunchagent"])
    check("launch: imklaunchagent stays headless", imkLaunch.launchDecision == .never)
    let finderLaunch = LaunchContext(arguments: ["/x/DoctKey"],
                                     forceSettings: false,
                                     parentProcessPaths: ["/sbin/launchd"])
    check("launch: Finder double-click shows on activation", finderLaunch.launchDecision == .showWhenActivated)
    let cliLaunch = LaunchContext(arguments: ["/x/DoctKey", "--print-status"],
                                  forceSettings: false,
                                  parentProcessPaths: [])
    check("launch: CLI flags never show a window", cliLaunch.launchDecision == .never)
}

// MARK: - Compatibility mode (CGEvent tap): pure planning + status logic

do {
    // append: the engine grew the word, so only the suffix is inserted.
    let first = CompatEditPlan.plan(for: KeyResult(op: .append,
                                                   text: "a",
                                                   word: "a",
                                                   composing: true,
                                                   consumed: true),
                                    shown: "")
    check("compat plan append: inserts the suffix", first.insert == "a" && first.backspaces == 0)
    check("compat plan append: consumes the physical key", first.consumesEvent && !first.passesEventThrough)
    check("compat plan append: tracks shown text", first.newShown == "a")

    let suffix = CompatEditPlan.plan(for: KeyResult(op: .append,
                                                    text: "ệt",
                                                    word: "việt",
                                                    composing: true,
                                                    consumed: true),
                                     shown: "vi")
    check("compat plan append: adds to the tracked word", suffix.insert == "ệt" && suffix.newShown == "việt")

    // replace: only the part that differs is edited (minimal synthetic events).
    let replace = CompatEditPlan.plan(for: KeyResult(op: .replace,
                                                     text: "việt",
                                                     word: "việt",
                                                     composing: true,
                                                     consumed: true),
                                      shown: "vieejt")
    check("compat plan replace: keeps the shared prefix", replace.backspaces == 4, "backspaces=\(replace.backspaces)")
    check("compat plan replace: posts only the changed suffix", replace.insert == "ệt", "insert=\(replace.insert)")
    check("compat plan replace: tracks the new shown word", replace.newShown == "việt")
    check("compat plan replace: consumes the physical key", replace.consumesEvent)

    // Backspace: a trailing character disappears, so one delete and no re-typing.
    let backspace = CompatEditPlan.plan(for: KeyResult(op: .replace,
                                                       text: "việ",
                                                       word: "việ",
                                                       composing: true,
                                                       consumed: true),
                                        shown: "việt")
    check("compat plan backspace: deletes one character", backspace.backspaces == 1, "backspaces=\(backspace.backspaces)")
    check("compat plan backspace: inserts nothing", backspace.insert.isEmpty, "insert=\(backspace.insert)")

    // Backspace that only moves/changes a tone still edits just the tail.
    let toneChange = CompatEditPlan.plan(for: KeyResult(op: .replace,
                                                        text: "hoa",
                                                        word: "hoa",
                                                        composing: true,
                                                        consumed: true),
                                         shown: "hoá")
    check("compat plan tone change: minimal edit",
          toneChange.backspaces == 1 && toneChange.insert == "a",
          "backspaces=\(toneChange.backspaces), insert=\(toneChange.insert)")

    // replace that ends composition (escape restores the literal keystrokes).
    let restore = CompatEditPlan.plan(for: KeyResult(op: .replace,
                                                     text: "as",
                                                     word: "as",
                                                     composing: false,
                                                     consumed: true),
                                      shown: "á")
    check("compat plan restore: deletes the rendered word", restore.backspaces == 1)
    check("compat plan restore: posts the literal keys", restore.insert == "as")
    check("compat plan restore: stops tracking the composition", restore.newShown.isEmpty)

    // replace with an empty word (backspace deleted the whole composition).
    let emptied = CompatEditPlan.plan(for: KeyResult(op: .replace,
                                                     text: "",
                                                     word: "",
                                                     composing: false,
                                                     consumed: true),
                                      shown: "a")
    check("compat plan replace empty: deletes one character",
          emptied.backspaces == 1 && emptied.insert.isEmpty && emptied.newShown.isEmpty)

    // commit: the delimiter passes through; the text is already on screen.
    let commit = CompatEditPlan.plan(for: KeyResult(op: .commit,
                                                    text: "việt",
                                                    word: "",
                                                    composing: false,
                                                    consumed: false),
                                     shown: "việt")
    check("compat plan commit: no screen edit", commit.backspaces == 0 && commit.insert.isEmpty)
    check("compat plan commit: lets the delimiter through",
          commit.passesEventThrough && !commit.consumesEvent)
    check("compat plan commit: resets the tracked word", commit.newShown.isEmpty)
    // Defensive: no tracked composition but a word to commit must not be lost.
    let untrackedCommit = CompatEditPlan.plan(for: KeyResult(op: .commit,
                                                             text: "abc",
                                                             word: "",
                                                             composing: false,
                                                             consumed: false),
                                              shown: "")
    check("compat plan commit: inserts untracked text",
          untrackedCommit.insert == "abc" && untrackedCommit.passesEventThrough)

    // pass: the application handles the key.
    let pass = CompatEditPlan.plan(for: KeyResult(op: .pass, composing: false, consumed: false), shown: "")
    check("compat plan pass: no edits", pass.insert.isEmpty && pass.backspaces == 0)
    check("compat plan pass: lets the key through", pass.passesEventThrough && !pass.consumesEvent)

    // none: the key is consumed without changing the screen.
    let none = CompatEditPlan.plan(for: KeyResult(op: .none, composing: true, consumed: true), shown: "a")
    check("compat plan none: consumes without edits",
          none.consumesEvent && !none.passesEventThrough && none.insert.isEmpty)
}

do {
    // Virtual key code classification (docs/SPEC.md engine key numbers).
    check("compat key: backspace maps to engine key 1", CompatKeyClassifier.engineKeyCode(for: KeyCode.backspace) == 1)
    check("compat key: forward delete maps to engine key 2", CompatKeyClassifier.engineKeyCode(for: KeyCode.forwardDelete) == 2)
    check("compat key: escape maps to engine key 3", CompatKeyClassifier.engineKeyCode(for: KeyCode.escape) == 3)
    check("compat key: return maps to engine key 4", CompatKeyClassifier.engineKeyCode(for: KeyCode.returnKey) == 4)
    check("compat key: keypad enter maps to engine key 4", CompatKeyClassifier.engineKeyCode(for: KeyCode.keypadEnter) == 4)
    check("compat key: tab maps to engine key 5", CompatKeyClassifier.engineKeyCode(for: KeyCode.tab) == 5)
    check("compat key: arrows map to engine key 6",
          CompatKeyClassifier.engineKeyCode(for: KeyCode.leftArrow) == 6
              && CompatKeyClassifier.engineKeyCode(for: KeyCode.upArrow) == 6)
    check("compat key: home/end/page keys map to engine key 6",
          CompatKeyClassifier.engineKeyCode(for: KeyCode.home) == 6
              && CompatKeyClassifier.engineKeyCode(for: KeyCode.pageDown) == 6)
    check("compat key: function keys map to engine key 6",
          CompatKeyClassifier.engineKeyCode(for: KeyCode.f1) == 6
              && CompatKeyClassifier.engineKeyCode(for: KeyCode.f12) == 6)
    check("compat key: letter keys are printable",
          CompatKeyClassifier.engineKeyCode(for: 0) == nil
              && CompatKeyClassifier.engineKeyCode(for: 14) == nil)
}

do {
    // Vietnamese status text mapping for the settings row / menu bar.
    let off = CompatibilityStatus(enabledByUser: false,
                                  running: false,
                                  permissionGranted: true,
                                  runsInCurrentProcess: true,
                                  lastError: nil)
    check("compat status: off text says it is off", off.displayText.contains("tắt"), "text=\(off.displayText)")
    check("compat status: off tone is neutral", off.tone == .neutral)

    let running = CompatibilityStatus(enabledByUser: true,
                                      running: true,
                                      permissionGranted: true,
                                      runsInCurrentProcess: true,
                                      lastError: nil)
    check("compat status: running text", running.displayText.contains("Đang chạy"), "text=\(running.displayText)")
    check("compat status: running tone is success", running.tone == .success)

    let missingPermission = CompatibilityStatus(enabledByUser: true,
                                                running: false,
                                                permissionGranted: false,
                                                runsInCurrentProcess: true,
                                                lastError: CompatibilityStatusText.permissionRequired)
    check("compat status: permission text mentions Accessibility",
          missingPermission.displayText.lowercased().contains("accessibility"))
    check("compat status: permission tone is danger", missingPermission.tone == .danger)

    let failed = CompatibilityStatus(enabledByUser: true,
                                     running: false,
                                     permissionGranted: true,
                                     runsInCurrentProcess: true,
                                     lastError: "CGEventTapCreate failed")
    check("compat status: error text includes the reason",
          failed.displayText.contains("CGEventTapCreate failed") && failed.tone == .danger)

    let settingsProcess = CompatibilityStatus(enabledByUser: true,
                                              running: false,
                                              permissionGranted: false,
                                              runsInCurrentProcess: false,
                                              lastError: nil)
    check("compat status: --settings process reports the tap lives elsewhere",
          settingsProcess.tone == .neutral && settingsProcess.displayText.contains("chạy nền"))
}

do {
    // Engine config payload for the compat core instance.
    let json = CompatibilityEngineConfig.json(mode: "vi", method: "vni", toneStyle: "traditional", smartEnglish: false)
    let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    check("compat config: valid JSON", object != nil)
    check("compat config: carries method", object?["method"] as? String == "vni")
    check("compat config: carries tone style", object?["tone_style"] as? String == "traditional")
    check("compat config: carries smart english", object?["smart_english"] as? Bool == false)
}

do {
    // start() without Accessibility permission must fail gracefully and must not
    // even attempt to create a real event tap (this test machine may or may not
    // be trusted, so the seam is injected).
    var factoryCalls = 0
    let denied = CompatibilityTapController()
    denied.accessibilityTrustProvider = { false }
    denied.tapFactory = { _, _, _ in
        factoryCalls += 1
        return nil
    }
    let deniedResult = denied.start()
    check("compat start: permission denied result", deniedResult == .permissionDenied)
    check("compat start: permission denied leaves the tap stopped",
          !denied.isRunning && !denied.isEnabled)
    check("compat start: permission denied never creates a tap", factoryCalls == 0)
    check("compat start: permission denied sets a Vietnamese error",
          denied.lastError?.lowercased().contains("accessibility") == true)
    check("compat start: status reports missing permission",
          !denied.status(enabledByUser: true).permissionGranted)
    denied.stop()

    // Trusted, but CGEventTapCreate fails: still no crash, error surfaced.
    var failingFactoryCalls = 0
    let failing = CompatibilityTapController()
    failing.accessibilityTrustProvider = { true }
    failing.tapFactory = { _, _, _ in
        failingFactoryCalls += 1
        return nil
    }
    let failingResult = failing.start()
    check("compat start: tap creation failure reported", failingResult == .tapCreationFailed)
    check("compat start: tap creation attempted once", failingFactoryCalls == 1)
    check("compat start: tap creation failure leaves the tap stopped", !failing.isRunning)
    check("compat start: tap creation failure sets an error",
          failing.lastError?.isEmpty == false)
    failing.stop()
    check("compat stop: stopping an idle controller is safe", !failing.isRunning)
    let idle = CompatibilityTapController()
    idle.resetComposition()
    check("compat reset: clearing an idle controller is safe", !idle.isRunning && idle.shown.isEmpty)
}

do {
    // compat_mode persistence (default off, round-trips through the config file).
    let temporaryPath = NSTemporaryDirectory() + "doctkey-config-compat-\(UUID().uuidString).json"
    let config = Config(path: temporaryPath)
    check("config: compat mode defaults to off", config.compatMode == false)
    check("config: compat mode is not sent to the engine", !config.engineJSON.contains("compat_mode"))
    config.compatMode = true
    config.save()
    let reloaded = Config(path: temporaryPath)
    check("config: compat mode round-trips", reloaded.compatMode == true)
    check("config: compat mode is written to disk",
          (try? String(contentsOfFile: temporaryPath, encoding: .utf8))?.contains("compat_mode") == true)
    try? FileManager.default.removeItem(atPath: temporaryPath)
}

do {
    // Launch-at-login (SMAppService) status text mapping — pure, no system call.
    check("login item: enabled text", LaunchAtLoginText.displayText(for: .enabled).contains("Đã bật"))
    check("login item: disabled text", LaunchAtLoginText.displayText(for: .disabled).contains("Chưa bật"))
    check("login item: requires-approval text mentions Login Items",
          LaunchAtLoginText.displayText(for: .requiresApproval).contains("Login Items"))
    check("login item: not-found text guides to the installed copy",
          LaunchAtLoginText.displayText(for: .notFound).contains("đã cài"))
    check("login item: error text includes the reason",
          LaunchAtLoginText.displayText(for: .unavailable("boom")).contains("boom"))
    check("login item: registered states look switched on",
          LaunchAtLoginState.enabled.isRegistered && LaunchAtLoginState.requiresApproval.isRegistered)
    check("login item: unregistered states look switched off",
          !LaunchAtLoginState.disabled.isRegistered && !LaunchAtLoginState.notFound.isRegistered)
    check("login item: tone mapping",
          LaunchAtLoginText.tone(for: .enabled) == .success
              && LaunchAtLoginText.tone(for: .requiresApproval) == .warning
              && LaunchAtLoginText.tone(for: .disabled) == .neutral)
    check("login item: repo build hint mentions the repo build",
          LaunchAtLoginText.repositoryBuildHint.contains("repo"))
}

do {
    // KeyResult.decode fast UTF-8 JSON parser edge cases.
    let escaped = KeyResult.decode(#"{"op":"replace","text":"a\"b\\c\nd\te\u00e1","word":"😀 \uD83D\uDE00","raw":"r","composing":true,"consumed":false,"mode":"en","method":"vni","tone_style":"traditional","smart":false,"changed":true}"#)
    check("decode: escaped strings and \\u00e1",
          escaped.op == .replace && escaped.text == "a\"b\\c\nd\teá",
          "text=\(escaped.text)")
    check("decode: UTF-16 surrogate pair",
          escaped.word == "😀 😀",
          "word=\(escaped.word)")
    check("decode: valid flags and enums",
          escaped.composing && !escaped.consumed && escaped.mode == "en"
              && escaped.method == "vni" && escaped.toneStyle == "traditional"
              && !escaped.smart && escaped.changed)

    let unknownNested = KeyResult.decode(#"{"extra":{"a":[1,true,false,null,-3.14e+2,{"k":"v"}]},"op":"append","text":"x"}"#)
    check("decode: skips unknown nested objects/arrays",
          unknownNested.op == .append && unknownNested.text == "x")

    let wrongTypes = KeyResult.decode(#"{"op":123,"text":null,"word":["a"],"composing":"yes","consumed":1,"mode":false,"method":42,"tone_style":{},"smart":"no","changed":null}"#)
    check("decode: wrong value types keep defaults",
          wrongTypes.op == .none && wrongTypes.text.isEmpty && wrongTypes.word.isEmpty
              && !wrongTypes.composing && !wrongTypes.consumed && wrongTypes.mode == "vi"
              && wrongTypes.method == "telex" && wrongTypes.toneStyle == "modern"
              && wrongTypes.smart && !wrongTypes.changed)

    let emptyEnums = KeyResult.decode(#"{"op":"state","mode":"","method":"","tone_style":""}"#)
    check("decode: empty enum strings keep defaults",
          emptyEnums.op == .state && emptyEnums.mode == "vi"
              && emptyEnums.method == "telex" && emptyEnums.toneStyle == "modern")

    for bad in ["{", "{\"op\":\"append\"} trailing", "{\"text\":\"\\u12\"}", "{\"text\":\"\\uD800\"}", "{\"text\":\"\n\"}", "[]", "123", ""] {
        let r = KeyResult.decode(bad)
        check("decode: malformed JSON returns .none (\(bad.debugDescription))",
              r.op == .none && r.text.isEmpty && r.mode == "vi")
    }
}

do {
    // KeyHandler direct mode minimal-replace and no-op commit checks.
    final class CountingHost: TextHost {
        let inner = MockHost()
        var insertCalls: [String] = []
        var replaceCalls: [(Int, String)] = []

        func insertText(_ text: String) {
            insertCalls.append(text)
            inner.insertText(text)
        }

        func replaceTrailing(_ utf16Length: Int, with text: String) {
            replaceCalls.append((utf16Length, text))
            inner.replaceTrailing(utf16Length, with: text)
        }

        func setMarkedText(_ text: String) { inner.setMarkedText(text) }
        func commitMarkedText(with text: String) { inner.commitMarkedText(with: text) }
    }

    let core = DoctKeyCore(configJSON: #"{"mode":"vi","method":"telex","smart_english":true}"#)
    let handler = KeyHandler(core: core, insertMode: .direct)
    let spy = CountingHost()
    handler.attach(host: spy)
    for ch in "vieejt" {
        _ = handler.handle(KeyInput(characters: String(ch)))
    }
    check("direct minimal replace: việt composed", spy.inner.documentText == "việt")
    let replacesBeforeBS = spy.replaceCalls.count
    _ = handler.handle(KeyInput(keyCode: KeyCode.backspace))
    check("direct minimal replace: <BS> deletes 1 trailing unit only",
          spy.replaceCalls.count == replacesBeforeBS + 1
              && spy.replaceCalls.last?.0 == 1
              && spy.replaceCalls.last?.1 == "")
    check("direct minimal replace: document is việ", spy.inner.documentText == "việ")
    _ = handler.handle(KeyInput(characters: "t"))
    let replacesBeforeCommit = spy.replaceCalls.count
    let commitConsumed = handler.handle(KeyInput(characters: " "))
    check("direct commit: space not consumed", !commitConsumed)
    check("direct commit: skips redundant replaceTrailing when shown == text",
          spy.replaceCalls.count == replacesBeforeCommit)
    spy.inner.insertText(" ")

    _ = handler.handle(KeyInput(characters: "a"))
    _ = handler.handle(KeyInput(characters: "s"))
    let escConsumed = handler.handle(KeyInput(keyCode: KeyCode.escape))
    check("direct escape: consumed and restores literal",
          escConsumed && spy.inner.documentText == "việt as")
}

do {
    // CompatEditPlan.diff for equal strings and CompatibilityTapController config-change reset.
    let noopReplace = CompatEditPlan.plan(for: KeyResult(op: .replace,
                                                         text: "abc",
                                                         word: "abc",
                                                         composing: true,
                                                         consumed: true),
                                          shown: "abc")
    check("compat plan replace equal strings: no edits",
          noopReplace.backspaces == 0 && noopReplace.insert.isEmpty && noopReplace.newShown == "abc")

    let controller = CompatibilityTapController()
    controller.accessibilityTrustProvider = { true }
    controller.tapFactory = { _, _, _ in
        CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, nil, nil)
    }
    controller.tapEnabler = { _, _ in }
    let startResult = controller.start()
    check("compat controller: test tap starts", startResult == .started && controller.isRunning)
    controller.updateConfig(mode: "en", method: "telex", toneStyle: "modern", smart: true, insertMode: .direct)
    controller.updateConfig(mode: "vi", method: "vni", toneStyle: "traditional", smart: false, insertMode: .direct)
    check("compat controller: updateConfig leaves clean state", !controller.isComposing && controller.shown.isEmpty)
    controller.stop()
}

do {
    // Config.saveAsync + flushPendingSave round-trip persistence.
    let temporaryPath = NSTemporaryDirectory() + "doctkey-config-async-\(UUID().uuidString).json"
    let config = Config(path: temporaryPath)
    config.mode = "en"
    config.compatMode = true
    config.saveAsync(debounce: 0.02)
    config.mode = "vi"
    config.method = "vni"
    config.saveAsync(debounce: 0.02)
    config.flushPendingSave()

    let reloaded = Config(path: temporaryPath)
    check("config saveAsync + flush: latest mode persisted", reloaded.mode == "vi", "mode=\(reloaded.mode)")
    check("config saveAsync + flush: latest method persisted", reloaded.method == "vni", "method=\(reloaded.method)")
    check("config saveAsync + flush: compatMode persisted", reloaded.compatMode == true)
    try? FileManager.default.removeItem(atPath: temporaryPath)
}

do {
    // CompatEditPlan physical Backspace passthrough + KeyHandler held Backspace + free-order Vietnamese.
    let singleBackspace = CompatEditPlan.plan(for: KeyResult(op: .replace,
                                                             text: "việ",
                                                             word: "việ",
                                                             composing: true,
                                                             consumed: true),
                                              shown: "việt")
    check("compat passthrough: true for physical backspace single-char delete",
          singleBackspace.canPassThroughPhysicalBackspace(keyCode: KeyCode.backspace))
    check("compat passthrough: false for non-backspace keyCode",
          !singleBackspace.canPassThroughPhysicalBackspace(keyCode: KeyCode.forwardDelete))

    let toneRewrite = CompatEditPlan.plan(for: KeyResult(op: .replace,
                                                         text: "hoa",
                                                         word: "hoa",
                                                         composing: true,
                                                         consumed: true),
                                          shown: "hoá")
    check("compat passthrough: false when insert is non-empty",
          !toneRewrite.canPassThroughPhysicalBackspace(keyCode: KeyCode.backspace))

    let multiDelete = CompatEditPlan.plan(for: KeyResult(op: .replace,
                                                         text: "a",
                                                         word: "a",
                                                         composing: true,
                                                         consumed: true),
                                          shown: "abc")
    check("compat passthrough: false when backspaces != 1",
          !multiDelete.canPassThroughPhysicalBackspace(keyCode: KeyCode.backspace))

    for mode in InsertMode.allCases {
        let core = DoctKeyCore(configJSON: #"{"mode":"vi","method":"telex","smart_english":true}"#)
        let handler = KeyHandler(core: core, insertMode: mode)
        let host = MockHost()
        handler.attach(host: host)
        drive("vieejt", handler: handler, host: host)
        let repeatConsumed = handler.handle(KeyInput(keyCode: KeyCode.backspace, isRepeat: true))
        check("held backspace commits & passes through [\(mode.rawValue)]",
              !repeatConsumed && !handler.isComposing && host.markedRange == nil && host.documentText == "việt",
              "consumed=\(repeatConsumed) doc=\(host.documentText)")
    }

    for (keys, expected) in [
        ("toio", "tôi"),
        ("toiso", "tối"),
        ("uuw", "ưu"),
        ("quawng", "quăng"),
        ("ruouwj", "rượu"),
        ("dduwongf", "đường"),
        ("been", "bên"),
        ("teen", "tên"),
        ("mootj", "một")
    ] {
        let core = DoctKeyCore(configJSON: #"{"mode":"vi","method":"telex","smart_english":true}"#)
        let handler = KeyHandler(core: core, insertMode: .direct)
        let host = MockHost()
        handler.attach(host: host)
        drive(keys, handler: handler, host: host)
        handler.commitComposition()
        check("swift free-order/everyday Vietnamese: \(keys) -> \(expected)",
              host.documentText == expected,
              "got=\(host.documentText)")
    }
}

print("")
print("Fixture runs: \(passedRuns)/\(totalRuns) passed" +
      (failures.isEmpty ? " (both insert modes)" : ", \(failures.count) failed"))
print("Compatibility-mode fixture runs: \(passedCompatibilityRuns)/\(totalCompatibilityRuns) passed" +
      (compatibilityFailures.isEmpty ? "" : ", \(compatibilityFailures.count) failed"))
print("Extra checks: \(extraPassed)/\(extraPassed + extraFailed) passed")

if failures.isEmpty && compatibilityFailures.isEmpty && extraFailed == 0 {
    print("RESULT: OK")
    exit(0)
} else {
    print("RESULT: FAILED")
    exit(1)
}
