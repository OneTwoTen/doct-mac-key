import Cocoa

/// Application delegate: owns the shared engine, the key handler, the menu-bar
/// item, the Carbon hotkeys and the settings window. `InputController` reaches
/// the same shared state through `AppDelegate.shared` (InputMethodKit instantiates
/// controllers itself).
///
/// Two launch flavours share this class:
///
///  * normal IME/agent launch: menu-bar item + hotkeys, and the settings window
///    only for explicit user actions (`applicationShouldHandleReopen`,
///    `--settings`) or a Finder double-click heuristic;
///  * settings-only launch (`--settings`): no IMKServer, no extra menu-bar item
///    and no global hotkeys (another DoctKey instance may already own them), just
///    the settings window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) static var shared: AppDelegate?

    let config: Config
    let core: DoctKeyCore
    let keyHandler: KeyHandler
    /// Global CGEventTap fallback (own engine instance, independent from
    /// `keyHandler`). Started/stopped from `config.compatMode`.
    let compatibility: CompatibilityTapController

    /// Set by `main.swift` before `NSApplication.run()`.
    var launchContext: LaunchContext?
    /// `--settings` launch: the process exists only to show the settings window.
    var settingsOnly = false

    private var hotkeyManager: HotkeyManager?
    private var statusMenu: StatusMenu?
    private var updater: AutoUpdater?
    private(set) var settingsWindow: SettingsWindowController?

    /// True between a Finder-launch decision and the actual app activation.
    private var pendingUserLaunch = false

    override init() {
        let loadedConfig = Config()
        let engine = DoctKeyCore(configJSON: loadedConfig.engineJSON)
        config = loadedConfig
        core = engine
        keyHandler = KeyHandler(core: engine, insertMode: loadedConfig.insertMode)
        let tapController = CompatibilityTapController()
        tapController.updateConfig(mode: loadedConfig.mode,
                                   method: loadedConfig.method,
                                   toneStyle: loadedConfig.toneStyle,
                                   smart: loadedConfig.smartEnglish,
                                   insertMode: loadedConfig.insertMode)
        compatibility = tapController
        super.init()
        AppDelegate.shared = self
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep several DoctKey processes (IME + settings-only) in sync: the
        // settings process posts this after persisting config.
        DistributedNotificationCenter.default().addObserver(self,
                                                            selector: #selector(configChangedExternally(_:)),
                                                            name: DoctKeyNotifications.configChanged,
                                                            object: nil)

        if settingsOnly {
            showSettingsWindow()
            NSLog("DoctKey: settings window opened (settings-only launch)")
            return
        }

        // Focus moved to another app: the CGEventTap cannot know where the caret
        // is, so drop its composition tracking instead of risking backspaces in
        // the wrong document.
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(activeApplicationChanged(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil)

        setupStatusMenu()
        registerHotkeys()
        updater = AutoUpdater { [weak self] status in
            self?.statusMenu?.updateUpdateStatus(status)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.updater?.checkForUpdates { result in
                if case .available(let version) = result {
                    NSLog("DoctKey: version %@ is available", version)
                }
            }
        }
        NSLog("DoctKey \(core.version) ready (mode=\(config.mode), method=\(config.method), insert=\(keyHandler.insertMode.rawValue), compat=\(config.compatMode))")
        // The compatibility tap is independent from InputMethodKit: start it on
        // launch whenever the persisted switch is on (the app then keeps running
        // headless as an accessory app; the menu bar is the UI).
        syncCompatibilityTap()
        applyLaunchDecision()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Do not lose the word the user was in the middle of typing.
        if keyHandler.isComposing {
            keyHandler.commitComposition()
        }
        // The word is already on screen in the focused app; just tear the tap
        // down (no synthetic edits on the way out).
        compatibility.stop()
        hotkeyManager?.unregisterAll()
        config.save()
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The IME/agent keeps running via the menu-bar item — and in particular
        // the compatibility tap must survive closing the settings window (it is
        // global, so it must keep composing with no windows open). Only the
        // settings-only `--settings` process has nothing left to do.
        settingsOnly
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Finder double-click while DoctKey already runs (typically the IME
        // instance): treat it as "open settings", never let AppKit create other
        // windows for an LSUIElement app.
        showSettingsWindow()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if pendingUserLaunch {
            finishPendingUserLaunch(force: true)
        }
        // The user may have just granted Accessibility permission in System
        // Settings: retry the tap (no prompt) so the switch starts working
        // without a relaunch. Also refreshes the Settings status row.
        retryCompatibilityTapIfNeeded()
    }

    // MARK: - Launch policy

    private func applyLaunchDecision() {
        guard let launchContext else { return }
        switch launchContext.launchDecision {
        case .showImmediately:
            showSettingsWindow()
        case .showWhenActivated:
            pendingUserLaunch = true
            // `applicationDidBecomeActive` normally fires for a Finder launch; the
            // timer is a safety net for the (rare) case where activation happens
            // before didFinishLaunching.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.finishPendingUserLaunch(force: false)
            }
        case .never:
            break
        }
    }

    private func finishPendingUserLaunch(force: Bool) {
        guard pendingUserLaunch else { return }
        pendingUserLaunch = false
        if force || NSApp.isActive {
            showSettingsWindow()
        }
    }

    // MARK: - State

    var menuState: AppMenuState {
        AppMenuState(mode: config.mode,
                     method: config.method,
                     toneStyle: config.toneStyle,
                     smartEnglish: config.smartEnglish,
                     insertMode: keyHandler.insertMode,
                     compatibilityMode: config.compatMode)
    }

    /// Status row shown by the settings window (permission / running / error).
    var compatibilityStatus: CompatibilityStatus {
        // A `--settings` process never owns the tap; the running IME/agent does.
        compatibility.status(enabledByUser: config.compatMode,
                             runsInCurrentProcess: !settingsOnly)
    }

    /// Current login-item state (SMAppService is the source of truth).
    var launchAtLoginState: LaunchAtLoginState { LaunchAtLogin.currentState() }

    var appVersion: String { AppInfo.shortVersion() }
    var runningBundlePath: String { Bundle.main.bundleURL.path }
    var configFilePath: String { config.path }

    // MARK: - Toggles (called by hotkeys / menu)

    func toggleMode() {
        runCommand(#"{"cmd":"toggle_mode"}"#)
    }

    func toggleMethod() {
        runCommand(#"{"cmd":"toggle_method"}"#)
    }

    func toggleToneStyle() {
        runCommand(#"{"cmd":"toggle_tone_style"}"#)
    }

    func toggleSmartEnglish() {
        runCommand(#"{"cmd":"toggle_smart"}"#)
    }

    func toggleCompatibilityMode() {
        let enabling = !config.compatMode
        setCompatibilityMode(enabling)
        // Same one-shot prompt policy as the settings switch: enabling without
        // Accessibility permission explains itself and asks for the permission.
        if enabling, !compatibilityStatus.permissionGranted {
            requestCompatibilityPermission()
        }
    }

    // MARK: - Parameterised setters (called by the settings window)

    func setMode(_ mode: String) {
        guard mode == "vi" || mode == "en", mode != config.mode else { return }
        runCommand("{\"cmd\":\"set_mode\",\"mode\":\"\(mode)\"}")
    }

    func setMethod(_ method: String) {
        guard method == "telex" || method == "vni", method != config.method else { return }
        runCommand("{\"cmd\":\"set_method\",\"method\":\"\(method)\"}")
    }

    func setToneStyle(_ toneStyle: String) {
        guard toneStyle == "modern" || toneStyle == "traditional",
              toneStyle != config.toneStyle else { return }
        runCommand("{\"cmd\":\"set_tone_style\",\"tone_style\":\"\(toneStyle)\"}")
    }

    func setSmartEnglish(_ enabled: Bool) {
        guard enabled != config.smartEnglish else { return }
        runCommand("{\"cmd\":\"set_smart\",\"smart\":\(enabled ? "true" : "false")}")
    }

    func setInsertMode(_ mode: InsertMode) {
        guard mode != keyHandler.insertMode else { return }
        keyHandler.setInsertMode(mode)
        config.insertMode = mode
        persistConfig()
        statusMenu?.update(state: menuState, flash: true)
        settingsWindow?.refreshAll()
        publishConfigChange()
    }

    /// Enables/disables the signing-independent CGEventTap fallback. Persists
    /// `compat_mode`, starts/stops the tap and refreshes the UI. Never prompts
    /// for Accessibility permission itself (the settings window does that once).
    func setCompatibilityMode(_ enabled: Bool) {
        guard enabled != config.compatMode else { return }
        config.compatMode = enabled
        persistConfig()
        syncCompatibilityTap()
        statusMenu?.update(state: menuState, flash: true)
        settingsWindow?.refreshAll()
        publishConfigChange()
    }

    /// Explicit "Kiểm tra lại": rebuilds the tap (e.g. the user has just granted
    /// Accessibility permission in System Settings).
    func retryCompatibilityTap() {
        guard !settingsOnly else { return }
        compatibility.stop()
        syncCompatibilityTap()
        statusMenu?.update(state: menuState)
    }

    /// Asks macOS to show the Accessibility prompt and returns the current trust
    /// state. Never crashes when permission is missing.
    @discardableResult
    func requestCompatibilityPermission() -> Bool {
        let granted = compatibility.requestAccessibilityPermission()
        settingsWindow?.refreshAll()
        statusMenu?.update(state: menuState)
        return granted
    }

    @discardableResult
    func openCompatibilityAccessibilitySettings() -> Bool {
        compatibility.openAccessibilitySettings()
    }

    /// Registers/unregisters the app as a login item (SMAppService). Returns a
    /// Vietnamese error message when the system rejects the change; nil on
    /// success.
    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> String? {
        let error = LaunchAtLogin.setEnabled(enabled)
        settingsWindow?.refreshAll()
        return error
    }

    /// Re-registers the Carbon hotkeys from `specs`, persists them and returns
    /// how many could actually be registered (best-effort: another app may own
    /// a shortcut).
    @discardableResult
    func applyHotkeys(_ specs: [String: String]) -> Int {
        config.updateHotkeys(specs)
        persistConfig()
        let registered = registerHotkeys()
        statusMenu?.update(state: menuState, flash: true)
        settingsWindow?.refreshAll()
        publishConfigChange()
        return registered
    }

    @discardableResult
    func resetHotkeys() -> Int {
        applyHotkeys(Config.defaultHotkeys)
    }

    func reloadConfig() {
        // Finish the current word first: the new config may change the mode.
        keyHandler.commitComposition()
        config.load()
        if !core.setConfig(config.engineJSON) {
            NSLog("DoctKey: engine rejected config JSON; keeping previous settings")
        }
        keyHandler.setInsertMode(config.insertMode)
        // A reloaded config may flip `compat_mode` or change the engine settings.
        syncCompatibilityTap()
        registerHotkeys()
        statusMenu?.update(state: menuState, flash: true)
        settingsWindow?.refreshAll()
        NSLog("DoctKey: config reloaded from %@", config.path)
    }

    func openConfig() {
        // Make sure the file exists before opening it.
        config.save()
        NSWorkspace.shared.open(URL(fileURLWithPath: config.path))
    }

    // MARK: - Settings window

    @discardableResult
    func showSettingsWindow(tab: SettingsTab? = nil) -> SettingsWindowController {
        let controller: SettingsWindowController
        if let existing = settingsWindow {
            controller = existing
        } else {
            controller = SettingsWindowController()
            settingsWindow = controller
        }
        controller.show(tab: tab)
        NSApp.activate(ignoringOtherApps: true)
        NSLog("DoctKey: settings window opened")
        return controller
    }

    /// Menu item "Giới thiệu DoctKey…": opens the About tab, which shows the
    /// version, install paths and config path.
    func showAbout() {
        showSettingsWindow(tab: .about)
    }

    private func checkForUpdatesFromMenu() {
        guard let updater else { return }
        updater.checkForUpdates { [weak self] result in
            switch result {
            case .current:
                self?.showUpdaterAlert(title: "DoctKey đã mới nhất",
                                       message: "Bạn đang dùng phiên bản mới nhất.",
                                       style: .informational)
            case .available(let version):
                self?.confirmUpdate(version: version)
            case .failed(let message):
                self?.showUpdaterAlert(title: "Không kiểm tra được cập nhật",
                                       message: message,
                                       style: .warning)
            case .alreadyChecking:
                break
            }
        }
    }

    private func confirmUpdate(version: String) {
        let alert = NSAlert()
        alert.messageText = "Đã có DoctKey \(version)"
        alert.informativeText = "DoctKey sẽ tải bản mới, xác minh chữ ký rồi cài vào vị trí hiện tại. Ứng dụng sẽ khởi động lại; macOS có thể yêu cầu quyền quản trị."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Cập nhật")
        alert.addButton(withTitle: "Để sau")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        updater?.installAvailableUpdate { [weak self] error in
            guard let error else { return }
            self?.showInstallFailure(error)
        }
    }

    /// Updating replaces the bundle that is installed in the system. When DoctKey
    /// was launched from the repository build instead, explain that and offer to
    /// switch to the installed copy where the update can actually be applied.
    private func showInstallFailure(_ error: AutoUpdater.InstallError) {
        let alert = NSAlert()
        alert.messageText = "Cập nhật DoctKey thất bại"
        alert.informativeText = error.message
        alert.alertStyle = .warning

        guard let installedPath = error.installedPath else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        alert.addButton(withTitle: "Chuyển sang bản đã cài")
        alert.addButton(withTitle: "Để sau")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: installedPath),
                                           configuration: configuration) { [weak self] _, launchError in
            guard launchError == nil else {
                self?.showUpdaterAlert(title: "Không mở được bản đã cài",
                                       message: "Hãy mở thủ công:\n\(installedPath)",
                                       style: .warning)
                return
            }
            // Only one DoctKey should own the menu bar, and update checks are
            // meaningful only from the installed copy.
            NSApp.terminate(nil)
        }
    }

    private func showUpdaterAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Cross-process synchronisation

    @objc private func configChangedExternally(_ notification: Notification) {
        guard !settingsOnly else { return }
        reloadConfig()
        NSLog("DoctKey: config changed by another DoctKey process; reloaded")
    }

    @objc private func activeApplicationChanged(_ notification: Notification) {
        guard !settingsOnly else { return }
        // Any activation change (including opening our own settings window) means
        // the caret context may be different: forget the tracked composition.
        guard notification.userInfo?[NSWorkspace.applicationUserInfoKey] is NSRunningApplication else {
            return
        }
        compatibility.resetComposition()
    }

    private func publishConfigChange() {
        // Only a settings-only process needs to notify the IME instance; doing it
        // from the IME process would just reload its own fresh state.
        guard settingsOnly else { return }
        DistributedNotificationCenter.default().postNotificationName(DoctKeyNotifications.configChanged,
                                                                     object: nil,
                                                                     userInfo: nil,
                                                                     deliverImmediately: true)
    }

    // MARK: - Internals

    private func runCommand(_ json: String) {
        let wasComposing = keyHandler.isComposing
        let result = keyHandler.command(json)
        if wasComposing {
            // Command handlers flush a half-typed word before changing settings
            // that would re-render it (tone style / smart / mode / method).
            NSLog("DoctKey: committed the current word before applying %@", json)
        }
        syncConfig(from: result)
        // Keep the compatibility tap's private engine in sync with the IME one.
        compatibility.updateConfig(mode: config.mode,
                                   method: config.method,
                                   toneStyle: config.toneStyle,
                                   smart: config.smartEnglish,
                                   insertMode: keyHandler.insertMode)
        persistConfig()
        statusMenu?.update(state: menuState, flash: true)
        settingsWindow?.refreshAll()
        publishConfigChange()
    }

    private func persistConfig() {
        if settingsOnly {
            config.save()
        } else {
            config.saveAsync()
        }
    }

    private func syncConfig(from result: KeyResult) {
        if result.mode == "vi" || result.mode == "en" { config.mode = result.mode }
        if result.method == "telex" || result.method == "vni" { config.method = result.method }
        if result.toneStyle == "modern" || result.toneStyle == "traditional" {
            config.toneStyle = result.toneStyle
        }
        config.smartEnglish = result.smart
    }

    // MARK: - Compatibility tap lifecycle

    /// Brings the CGEventTap in line with `config.compatMode`. Called on launch,
    /// after a config reload and after every settings change. Failures are
    /// reported through `compatibilityStatus` (never fatal).
    private func syncCompatibilityTap() {
        guard !settingsOnly else { return }
        compatibility.updateConfig(mode: config.mode,
                                   method: config.method,
                                   toneStyle: config.toneStyle,
                                   smart: config.smartEnglish,
                                   insertMode: keyHandler.insertMode)
        if config.compatMode {
            guard !compatibility.isRunning else { return }
            switch compatibility.start() {
            case .started:
                NSLog("DoctKey: compatibility mode (CGEventTap) started")
            case .permissionDenied:
                NSLog("DoctKey: compatibility mode needs Accessibility permission")
            case .tapCreationFailed, .engineUnavailable:
                NSLog("DoctKey: compatibility mode could not start (\(compatibility.lastError ?? "unknown"))")
            case .alreadyRunning:
                break
            }
        } else if compatibility.isRunning {
            compatibility.stop()
            NSLog("DoctKey: compatibility mode (CGEventTap) stopped")
        }
    }

    /// Retries without prompting when the user comes back after granting
    /// Accessibility permission. Cheap no-op when the switch is off.
    private func retryCompatibilityTapIfNeeded() {
        guard !settingsOnly, config.compatMode, !compatibility.isRunning else { return }
        compatibility.updateConfig(mode: config.mode,
                                   method: config.method,
                                   toneStyle: config.toneStyle,
                                   smart: config.smartEnglish,
                                   insertMode: keyHandler.insertMode)
        _ = compatibility.start()
        statusMenu?.update(state: menuState)
        settingsWindow?.refreshAll()
    }

    private func setupStatusMenu() {
        let actions = StatusMenu.Actions(
            openSettings: { [weak self] in self?.showSettingsWindow() },
            checkForUpdates: { [weak self] in self?.checkForUpdatesFromMenu() },
            toggleMode: { [weak self] in self?.toggleMode() },
            toggleMethod: { [weak self] in self?.toggleMethod() },
            toggleToneStyle: { [weak self] in self?.toggleToneStyle() },
            toggleSmart: { [weak self] in self?.toggleSmartEnglish() },
            toggleCompatibility: { [weak self] in self?.toggleCompatibilityMode() },
            setInsertMode: { [weak self] mode in self?.setInsertMode(mode) },
            reloadConfig: { [weak self] in self?.reloadConfig() },
            openConfig: { [weak self] in self?.openConfig() },
            showAbout: { [weak self] in self?.showAbout() },
            quit: { NSApp.terminate(nil) }
        )
        let menu = StatusMenu(actions: actions)
        menu.update(state: menuState)
        statusMenu = menu
    }

    @discardableResult
    private func registerHotkeys() -> Int {
        let manager = hotkeyManager ?? HotkeyManager()
        let bindings: [HotkeyManager.Binding] = [
            HotkeyManager.Binding(id: 1,
                                  spec: config.hotkeys["toggle_mode"] ?? "",
                                  action: { [weak self] in self?.toggleMode() }),
            HotkeyManager.Binding(id: 2,
                                  spec: config.hotkeys["toggle_method"] ?? "",
                                  action: { [weak self] in self?.toggleMethod() }),
            HotkeyManager.Binding(id: 3,
                                  spec: config.hotkeys["toggle_tone_style"] ?? "",
                                  action: { [weak self] in self?.toggleToneStyle() }),
            HotkeyManager.Binding(id: 4,
                                  spec: config.hotkeys["toggle_smart"] ?? "",
                                  action: { [weak self] in self?.toggleSmartEnglish() }),
            HotkeyManager.Binding(id: 5,
                                  spec: config.hotkeys["reload_config"] ?? "",
                                  action: { [weak self] in self?.reloadConfig() })
        ]
        let count = manager.register(bindings)
        hotkeyManager = manager
        NSLog("DoctKey: registered \(count) global hotkey(s)")
        return count
    }
}
