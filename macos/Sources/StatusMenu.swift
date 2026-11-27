import Cocoa

/// Snapshot of the runtime state shown by the menu-bar item and its menu.
struct AppMenuState {
    let mode: String
    let method: String
    let toneStyle: String
    let smartEnglish: Bool
    let insertMode: InsertMode
    let compatibilityMode: Bool

    var shortTitle: String { mode == "vi" ? "VI" : "EN" }
    var methodName: String { method == "vni" ? "VNI" : "Telex" }
    var toneStyleName: String { toneStyle == "traditional" ? "Truyền thống" : "Hiện đại" }
    var fullTitle: String { "\(shortTitle) · \(methodName)" }
}

/// The menu-bar status item: `VI` / `EN` title plus the settings menu.
final class StatusMenu: NSObject {
    struct Actions {
        let openSettings: () -> Void
        let checkForUpdates: () -> Void
        let toggleMode: () -> Void
        let toggleMethod: () -> Void
        let toggleToneStyle: () -> Void
        let toggleSmart: () -> Void
        let toggleCompatibility: () -> Void
        let setInsertMode: (InsertMode) -> Void
        let reloadConfig: () -> Void
        let openConfig: () -> Void
        let showAbout: () -> Void
        let quit: () -> Void
    }

    private let statusItem: NSStatusItem
    private let actions: Actions

    private var modeItem: NSMenuItem?
    private var methodItem: NSMenuItem?
    private var toneItem: NSMenuItem?
    private var smartItem: NSMenuItem?
    private var compatibilityItem: NSMenuItem?
    private var updateItem: NSMenuItem?
    private var markedItem: NSMenuItem?
    private var directItem: NSMenuItem?

    private var lastState = AppMenuState(mode: "vi",
                                         method: "telex",
                                         toneStyle: "modern",
                                         smartEnglish: true,
                                         insertMode: .marked,
                                         compatibilityMode: false)
    private var flashToken = 0

    init(actions: Actions) {
        self.actions = actions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.title = "VI"
        statusItem.button?.toolTip = "DoctKey — Vietnamese input method"
        buildMenu()
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Refreshes the title/menu. `flash` briefly shows the full state
    /// (`VI · Telex`) before shrinking back to `VI` / `EN`.
    func update(state: AppMenuState, flash: Bool = false) {
        lastState = state
        applyMenuState(state)
        if flash {
            showFullTitle(state.fullTitle)
        } else {
            statusItem.button?.title = state.shortTitle
        }
    }

    func updateUpdateStatus(_ status: AutoUpdater.MenuStatus) {
        switch status {
        case .checking:
            updateItem?.title = "Đang kiểm tra cập nhật…"
            updateItem?.isEnabled = false
            updateItem?.toolTip = nil
        case .current:
            updateItem?.title = "Kiểm tra cập nhật… (đang mới nhất)"
            updateItem?.isEnabled = true
            updateItem?.toolTip = nil
        case .available(let version):
            updateItem?.title = "Cập nhật DoctKey lên \(version)…"
            updateItem?.isEnabled = true
            updateItem?.toolTip = "Bấm để tải và cài bản mới. macOS có thể yêu cầu quyền quản trị."
        case .downloading(let version):
            updateItem?.title = "Đang tải DoctKey \(version)…"
            updateItem?.isEnabled = false
        case .installing(let version):
            updateItem?.title = "Đang cài DoctKey \(version)…"
            updateItem?.isEnabled = false
        case .failed(let message):
            updateItem?.title = "Thử lại kiểm tra cập nhật…"
            updateItem?.isEnabled = true
            updateItem?.toolTip = message
        }
    }

    // MARK: - Menu construction

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Most discoverable entry: the full management/settings window.
        let settingsItem = addItem(to: menu,
                                   title: "Cài đặt…",
                                   action: #selector(menuOpenSettings(_:)))
        settingsItem.keyEquivalent = ","
        settingsItem.keyEquivalentModifierMask = .command

        updateItem = addItem(to: menu,
                             title: "Kiểm tra bản cập nhật…",
                             action: #selector(menuCheckForUpdates(_:)))

        menu.addItem(.separator())

        modeItem = addItem(to: menu,
                           title: "Tiếng Việt / English",
                           action: #selector(menuToggleMode(_:)))
        methodItem = addItem(to: menu,
                             title: "Kiểu gõ: Telex / VNI",
                             action: #selector(menuToggleMethod(_:)))
        toneItem = addItem(to: menu,
                           title: "Đặt dấu: Hiện đại / Truyền thống",
                           action: #selector(menuToggleToneStyle(_:)))
        smartItem = addItem(to: menu,
                            title: "Smart English",
                            action: #selector(menuToggleSmart(_:)))
        compatibilityItem = addItem(to: menu,
                                    title: "Chế độ tương thích (CGEvent): Tắt",
                                    action: #selector(menuToggleCompatibility(_:)))

        menu.addItem(.separator())

        let insertItem = NSMenuItem(title: "Chế độ chèn", action: nil, keyEquivalent: "")
        let insertMenu = NSMenu()
        insertMenu.autoenablesItems = false
        markedItem = addItem(to: insertMenu,
                             title: InsertMode.marked.displayName,
                             action: #selector(menuSetMarked(_:)))
        directItem = addItem(to: insertMenu,
                             title: InsertMode.direct.displayName,
                             action: #selector(menuSetDirect(_:)))
        insertItem.submenu = insertMenu
        menu.addItem(insertItem)

        menu.addItem(.separator())

        _ = addItem(to: menu,
                    title: "Nạp lại cấu hình (⌃⌥R)",
                    action: #selector(menuReloadConfig(_:)))
        _ = addItem(to: menu,
                    title: "Mở file cấu hình",
                    action: #selector(menuOpenConfig(_:)))

        menu.addItem(.separator())

        _ = addItem(to: menu,
                    title: "Giới thiệu DoctKey…",
                    action: #selector(menuAbout(_:)))
        let quitItem = addItem(to: menu,
                               title: "Thoát DoctKey",
                               action: #selector(menuQuit(_:)))
        quitItem.keyEquivalent = "q"

        statusItem.menu = menu
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func applyMenuState(_ state: AppMenuState) {
        modeItem?.title = state.mode == "vi"
            ? "Tiếng Việt / English — đang: Tiếng Việt"
            : "Tiếng Việt / English — đang: English"
        modeItem?.state = state.mode == "vi" ? .on : .off

        methodItem?.title = "Kiểu gõ: Telex / VNI — đang: \(state.methodName)"
        methodItem?.state = .off

        toneItem?.title = "Đặt dấu: Hiện đại / Truyền thống — đang: \(state.toneStyleName)"
        toneItem?.state = .off

        smartItem?.title = "Smart English (tự động nhận tiếng Anh)"
        smartItem?.state = state.smartEnglish ? .on : .off

        compatibilityItem?.title = state.compatibilityMode
            ? "Chế độ tương thích (CGEvent): Bật"
            : "Chế độ tương thích (CGEvent): Tắt"
        compatibilityItem?.state = state.compatibilityMode ? .on : .off

        markedItem?.state = state.insertMode == .marked ? .on : .off
        directItem?.state = state.insertMode == .direct ? .on : .off
    }

    private func showFullTitle(_ title: String) {
        flashToken += 1
        let token = flashToken
        statusItem.button?.title = title
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.flashToken == token else { return }
            self.statusItem.button?.title = self.lastState.shortTitle
        }
    }

    // MARK: - Menu actions

    @objc private func menuOpenSettings(_ sender: Any?) { actions.openSettings() }
    @objc private func menuCheckForUpdates(_ sender: Any?) { actions.checkForUpdates() }
    @objc private func menuToggleMode(_ sender: Any?) { actions.toggleMode() }
    @objc private func menuToggleMethod(_ sender: Any?) { actions.toggleMethod() }
    @objc private func menuToggleToneStyle(_ sender: Any?) { actions.toggleToneStyle() }
    @objc private func menuToggleSmart(_ sender: Any?) { actions.toggleSmart() }
    @objc private func menuToggleCompatibility(_ sender: Any?) { actions.toggleCompatibility() }
    @objc private func menuSetMarked(_ sender: Any?) { actions.setInsertMode(.marked) }
    @objc private func menuSetDirect(_ sender: Any?) { actions.setInsertMode(.direct) }
    @objc private func menuReloadConfig(_ sender: Any?) { actions.reloadConfig() }
    @objc private func menuOpenConfig(_ sender: Any?) { actions.openConfig() }
    @objc private func menuQuit(_ sender: Any?) { actions.quit() }

    @objc private func menuAbout(_ sender: Any?) {
        // The About tab of the settings window shows the version, install paths
        // and config path; keep one source of truth instead of a separate alert.
        actions.showAbout()
    }
}
