import Carbon
import Cocoa
import InputMethodKit

// Entry point of the InputMethodKit input method.
//
// Three modes of operation:
//
//  1. CLI helpers (used by scripts/install.sh and for debugging): the flags are
//     handled *before* the IMKServer is created, print the Carbon TIS OSStatus
//     and exit. On macOS 26+ the system no longer scans ~/Library/Input Methods,
//     so the installed app itself is the only reliable way to register/enable its
//     input source.
//
//  2. Settings-only launch (`--settings`): create NSApplication + AppDelegate and
//     show the management window, but do NOT create an IMKServer — another
//     DoctKey process may already be the running input method (a second server
//     with the same connection name would fail). The window is the whole purpose
//     of this process; closing it quits.
//
//  3. Normal launch: create the IMKServer, install the app delegate and run the
//     application. The server must exist *before* NSApplication.run(); it owns the
//     connection named in Info.plist and instantiates `DoctKeyInputController` for
//     every client. The server and the delegate stay alive for the whole process.
//     If the server cannot be created (e.g. a second copy launched from Finder
//     while the IME instance runs), the app keeps running: the user may still get
//     the settings window, and the failure is logged.

// MARK: - Bundle / TIS helpers

let appBundle = Bundle.main
let appBundleURL = appBundle.bundleURL
let appBundleIdentifier = appBundle.bundleIdentifier ?? InputSourceManager.bundleIdentifier
let inputModeIdentifier = appBundleIdentifier + ".mode"

func printStatus(_ label: String, _ status: OSStatus) {
    if status == noErr {
        print("\(label): noErr (0)")
    } else {
        print("\(label): \(status) (error)")
    }
}

// MARK: - CLI actions

func cliRegisterInputSource() -> Int32 {
    print("DoctKey bundle: \(appBundleURL.path)")
    let status = InputSourceManager.registerInputSource(bundlePath: appBundleURL.path)
    printStatus("TISRegisterInputSource", status)
    return status == noErr ? 0 : 1
}

func cliEnableInputSource(alsoSelect: Bool) -> Int32 {
    print("DoctKey bundle: \(appBundleURL.path)")
    let sources = InputSourceManager.matchingInputSources()
    print("matching TIS input sources: \(sources.count)")
    guard !sources.isEmpty else {
        print("DoctKey input source not found in the TIS database.")
        print("Log out and back in (or reboot) so macOS rescans the input-source locations,")
        print("then run --register-input-source, or add it in System Settings → Keyboard → Input Sources.")
        return 1
    }
    var worstStatus: OSStatus = noErr
    for source in sources {
        let identifier = InputSourceManager.inputSourceIdentifier(source)
        let enableStatus = TISEnableInputSource(source)
        printStatus("TISEnableInputSource(\(identifier))", enableStatus)
        if enableStatus != noErr { worstStatus = enableStatus }
        if alsoSelect {
            let selectStatus = TISSelectInputSource(source)
            printStatus("TISSelectInputSource(\(identifier))", selectStatus)
            if selectStatus != noErr { worstStatus = selectStatus }
        }
    }
    return worstStatus == noErr ? 0 : 1
}

func cliPrintStatus() -> Int32 {
    print("DoctKey bundle: \(appBundleURL.path)")
    print("bundle identifier: \(appBundleIdentifier)")
    print("mode identifier: \(inputModeIdentifier)")
    let allSources = InputSourceManager.allInputSources()
    let matches = InputSourceManager.matchingInputSources(in: allSources)
    print("total TIS input sources: \(allSources.count)")
    print("matching DoctKey sources: \(matches.count)")
    for source in matches {
        let identifier = InputSourceManager.inputSourceIdentifier(source)
        let enabled = InputSourceManager.isEnabled(source) ? 1 : 0
        let selected = InputSourceManager.isSelected(source) ? 1 : 0
        print("  - \(identifier) enabled=\(enabled) selected=\(selected)")
    }
    return 0
}

// MARK: - CLI dispatch (must happen before IMKServer is created)

let cliArguments = CommandLine.arguments

if cliArguments.contains("--register-input-source") {
    exit(cliRegisterInputSource())
}
if cliArguments.contains("--enable-input-source") {
    exit(cliEnableInputSource(alsoSelect: false))
}
if cliArguments.contains("--select-input-source") {
    exit(cliEnableInputSource(alsoSelect: true))
}
if cliArguments.contains("--print-status") {
    exit(cliPrintStatus())
}
if cliArguments.contains("--print-login-item") {
    print("launch at login: \(LaunchAtLoginText.displayText(for: LaunchAtLogin.currentState()))")
    exit(0)
}
if cliArguments.contains("--register-login-item") {
    if let error = LaunchAtLogin.setEnabled(true) {
        print("login item registration failed: \(error)")
        exit(1)
    }
    print("login item registered")
    exit(0)
}
if cliArguments.contains("--unregister-login-item") {
    if let error = LaunchAtLogin.setEnabled(false) {
        print("login item removal failed: \(error)")
        exit(1)
    }
    print("login item removed")
    exit(0)
}

// MARK: - Settings-only launch

if cliArguments.contains("--settings") {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    delegate.settingsOnly = true
    delegate.launchContext = LaunchContext.current(arguments: cliArguments)
    application.delegate = delegate
    withExtendedLifetime(delegate) {
        application.run()
    }
    exit(0)
}

// MARK: - Normal application launch

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let connectionName = (appBundle.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String)
    ?? "DoctKey_Connection"

let server = IMKServer(name: connectionName, bundleIdentifier: appBundleIdentifier)
if server == nil {
    NSLog("DoctKey: could not create IMKServer (connection=%@, bundle=%@); continuing without the input-method server",
          connectionName, appBundleIdentifier)
} else {
    NSLog("DoctKey: IMKServer listening on %@", connectionName)
}

let delegate = AppDelegate()
delegate.launchContext = LaunchContext.current(arguments: cliArguments)
application.delegate = delegate

// Run forever. `withExtendedLifetime` makes the strong references explicit: the
// server would otherwise be released as soon as this scope ends.
withExtendedLifetime((server, delegate)) {
    application.run()
}
