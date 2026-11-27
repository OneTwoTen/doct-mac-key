import Carbon
import Cocoa

/// Tabs of the settings window (raw values match `NSTabView` item indexes).
enum SettingsTab: Int {
    case general = 0
    case hotkeys = 1
    case status = 2
    case about = 3
}

/// The management/settings window, built programmatically with AppKit (no XIB).
///
/// Layout: one reusable `NSWindow` titled "DoctKey — Cài đặt" with four tabs:
///
///  * **Chung** — mode/method/tone/smart/insert-mode, bound live to
///    `AppDelegate` (every change goes through `KeyHandler.command`, so an open
///    composition is committed first, then persisted).
///  * **Phím tắt** — the five global hotkeys, validated with `Config.validateHotkeys`,
///    re-registered immediately with Carbon.
///  * **Trạng thái** — the macOS 26 pain point: TIS registration state, install
///    paths, code signature, install/update (with optional signing identity),
///    uninstall, System Settings shortcut and a diagnostic report to paste.
///  * **Giới thiệu** — version, core version, paths, config and quit.
final class SettingsWindowController: NSObject {
    private let window: NSWindow
    private let tabView = NSTabView()
    private var hasCentered = false

    // MARK: General tab controls

    private var modeControl: NSSegmentedControl!
    private var methodControl: NSSegmentedControl!
    private var toneControl: NSSegmentedControl!
    private var smartSwitch: NSSwitch!
    private var insertControl: NSSegmentedControl!
    private var generalConfigPathLabel: NSTextField!

    // MARK: Compatibility mode (CGEvent tap) / launch at login

    private var compatSwitch: NSSwitch!
    private var compatStatusLabel: NSTextField!
    private var compatPermissionButton: NSButton!
    private var compatOpenSettingsButton: NSButton!
    private var compatRecheckButton: NSButton!
    private var launchAtLoginSwitch: NSSwitch!
    private var launchAtLoginStatusLabel: NSTextField!
    private var launchAtLoginHintLabel: NSTextField!

    // MARK: Hotkeys tab controls

    private var hotkeyFields: [String: NSTextField] = [:]
    private var hotkeyErrorLabels: [String: NSTextField] = [:]
    private var hotkeyStatusLabel: NSTextField!

    // MARK: Status tab controls

    private var statusStateLabel: NSTextField!
    private var statusHintLabel: NSTextField!
    private var sourceSummaryLabel: NSTextField!
    private var installedPathLabel: NSTextField!
    private var runningPathLabel: NSTextField!
    private var versionLabel: NSTextField!
    private var signatureLabel: NSTextField!
    private var identitiesLabel: NSTextField!
    private var configPathLabel: NSTextField!
    private var buildWarningRow: NSStackView!
    private var buildWarningLabel: NSTextField!
    private var refreshButton: NSButton!
    private var registerButton: NSButton!
    private var enableButton: NSButton!
    private var selectButton: NSButton!
    private var installButton: NSButton!
    private var uninstallButton: NSButton!
    private var signingPopup: NSPopUpButton!
    private var signingHintLabel: NSTextField!
    private var actionStatusLabel: NSTextField!

    // MARK: About tab controls

    private var aboutVersionLabel: NSTextField!
    private var aboutCoreLabel: NSTextField!
    private var aboutPathsLabel: NSTextField!
    private var aboutConfigLabel: NSTextField!
    private var aboutHotkeysLabel: NSTextField!

    // MARK: State

    private var isSyncing = false
    private var installInProgress = false
    private var deepStatusToken = 0
    private var latestSnapshot: InputSourceSnapshot?
    private var latestSignature: SignatureDescription?
    private var latestIdentities: [SigningIdentity] = []
    /// Options of the signing popup: nil = ad-hoc.
    private var signingOptions: [SigningIdentity?] = [nil]
    private var selectedSigningIdentity: SigningIdentity?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var selectedTab: SettingsTab? {
        guard let raw = tabView.selectedTabViewItem?.identifier as? Int else { return nil }
        return SettingsTab(rawValue: raw)
    }

    // MARK: - Init

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered,
                          defer: false)
        window.title = "DoctKey — Cài đặt"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 600)
        window.titlebarAppearsTransparent = false
        super.init()
        buildUI()
    }

    // MARK: - Public API

    func show(tab: SettingsTab? = nil) {
        if let tab {
            tabView.selectTabViewItem(at: tab.rawValue)
        }
        if !hasCentered {
            // Center on the screen with the menu bar (NSScreen.main); plain
            // `center()` can pick a secondary display when several are attached.
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                let size = window.frame.size
                window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                              y: visible.midY - size.height / 2))
            } else {
                window.center()
            }
            hasCentered = true
        }
        refreshAll(deepStatus: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Refreshes visible tabs from the live `AppDelegate` state. `deepStatus` also
    /// re-reads the code signature and the available signing identities on a
    /// background queue (external processes, so only on show / explicit refresh / after install).
    func refreshAll(deepStatus: Bool = false) {
        guard window.isVisible || deepStatus else { return }
        refreshGeneral()
        refreshHotkeys()
        if deepStatus || selectedTab == .status {
            refreshStatus(deep: deepStatus)
        }
        refreshAbout()
    }

    // MARK: - UI construction

    private func buildUI() {
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.tabViewType = .topTabsBezelBorder
        tabView.delegate = self
        contentView.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])
        window.contentView = contentView

        addTab(.general, title: "Chung", view: buildGeneralTab())
        addTab(.hotkeys, title: "Phím tắt", view: buildHotkeysTab())
        addTab(.status, title: "Trạng thái", view: buildStatusTab())
        addTab(.about, title: "Giới thiệu", view: buildAboutTab())
    }

    private func addTab(_ tab: SettingsTab, title: String, view: NSView) {
        let container = NSView()
        let scroll = makeScrollableView(for: view)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        let item = NSTabViewItem(identifier: tab.rawValue)
        item.label = title
        item.view = container
        tabView.addTabViewItem(item)
    }

    /// Wraps a vertical stack in a scroll view so the tall Status tab fits on
    /// small screens. The document view is flipped so content starts at the top.
    private func makeScrollableView(for content: NSView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        content.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -16),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor)
        ])
        return scrollView
    }

    // MARK: - General tab

    private func buildGeneralTab() -> NSView {
        modeControl = NSSegmentedControl(labels: ["Tiếng Việt", "English"],
                                         trackingMode: .selectOne,
                                         target: self,
                                         action: #selector(modeChanged(_:)))
        modeControl.segmentStyle = .rounded
        modeControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        methodControl = NSSegmentedControl(labels: ["Telex", "VNI"],
                                           trackingMode: .selectOne,
                                           target: self,
                                           action: #selector(methodChanged(_:)))
        methodControl.segmentStyle = .rounded
        methodControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        toneControl = NSSegmentedControl(labels: ["Hiện đại", "Truyền thống"],
                                         trackingMode: .selectOne,
                                         target: self,
                                         action: #selector(toneStyleChanged(_:)))
        toneControl.segmentStyle = .rounded
        toneControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        smartSwitch = NSSwitch(frame: .zero)
        smartSwitch.target = self
        smartSwitch.action = #selector(smartChanged(_:))

        insertControl = NSSegmentedControl(labels: ["Marked (mặc định)", "Direct"],
                                           trackingMode: .selectOne,
                                           target: self,
                                           action: #selector(insertModeChanged(_:)))
        insertControl.segmentStyle = .rounded
        insertControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        let smartHelp = wrappingLabel("Ưu tiên tiếng Việt như UniKey: cách gõ tạo được âm tiết Việt thì bỏ dấu, từ không thể là tiếng Việt thì giữ nguyên phím gõ (hello, meeting, google). Tắt để luôn bỏ dấu.",
                                      size: 11,
                                      color: .secondaryLabelColor)
        let insertHelp = wrappingLabel("Marked hiển thị chữ đang gõ dưới dạng gạch chân (mặc định). Direct ghi trực tiếp vào tài liệu — dùng khi Terminal/VSCode hiển thị sai.",
                                       size: 11,
                                       color: .secondaryLabelColor)

        compatSwitch = NSSwitch(frame: .zero)
        compatSwitch.target = self
        compatSwitch.action = #selector(compatModeChanged(_:))

        compatStatusLabel = wrappingLabel("", size: 11, color: .secondaryLabelColor)

        compatPermissionButton = button("Cấp quyền Accessibility",
                                        action: #selector(grantAccessibilityTapped(_:)))
        compatOpenSettingsButton = button("Mở Accessibility Settings",
                                          action: #selector(openAccessibilitySettingsTapped(_:)))
        compatRecheckButton = button("Kiểm tra lại",
                                     action: #selector(recheckCompatibilityTapped(_:)))

        launchAtLoginSwitch = NSSwitch(frame: .zero)
        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(launchAtLoginChanged(_:))

        launchAtLoginStatusLabel = wrappingLabel("", size: 11, color: .secondaryLabelColor)
        launchAtLoginHintLabel = wrappingLabel(LaunchAtLoginText.repositoryBuildHint,
                                               size: 11,
                                               color: .systemOrange)
        launchAtLoginHintLabel.isHidden = true

        let compatHelp = wrappingLabel(
            "Dùng khi bộ gõ chuẩn chưa được macOS nhận: DoctKey ghép chữ trực tiếp vào ứng dụng đang dùng. "
            + "Cần quyền Accessibility. Nên chọn bố cục ABC và không chọn DoctKey làm nguồn nhập cùng lúc.",
            size: 11,
            color: .secondaryLabelColor)
        let launchAtLoginHelp = wrappingLabel(
            "Khởi động DoctKey cùng macOS (cần cho chế độ tương thích): DoctKey chạy nền không cửa sổ, "
            + "menu bar là nơi điều khiển.",
            size: 11,
            color: .secondaryLabelColor)

        generalConfigPathLabel = detailValueLabel(selectable: false)
        generalConfigPathLabel.textColor = .secondaryLabelColor

        let buttons = horizontalStack([
            button("Mở file cấu hình", action: #selector(openConfigTapped(_:))),
            button("Nạp lại cấu hình", action: #selector(reloadConfigTapped(_:)))
        ])

        let stack = verticalStack([
            sectionLabel("Cài đặt chung"),
            controlRow("Chế độ gõ:", control: modeControl),
            controlRow("Kiểu gõ:", control: methodControl),
            controlRow("Đặt dấu:", control: toneControl),
            controlRow("Ưu tiên tiếng Việt:", control: smartSwitch),
            smartHelp,
            separator(),
            controlRow("Chế độ chèn:", control: insertControl),
            insertHelp,
            separator(),
            sectionLabel("Chế độ tương thích (không cần cài bộ gõ)"),
            controlRow("Bật chế độ tương thích (CGEvent):", control: compatSwitch),
            compatHelp,
            compatStatusLabel,
            horizontalStack([compatPermissionButton, compatOpenSettingsButton, compatRecheckButton]),
            separator(),
            sectionLabel("Khởi động cùng macOS"),
            controlRow("Khởi động DoctKey cùng macOS:", control: launchAtLoginSwitch),
            launchAtLoginHelp,
            launchAtLoginHintLabel,
            launchAtLoginStatusLabel,
            separator(),
            generalConfigPathLabel,
            buttons,
            wrappingLabel("Mọi thay đổi được áp dụng ngay lập tức, từ đang gõ dở sẽ được chốt trước khi đổi, và được lưu vào file cấu hình.",
                          size: 11,
                          color: .secondaryLabelColor)
        ])
        return stack
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        guard !isSyncing else { return }
        AppDelegate.shared?.setMode(sender.selectedSegment == 0 ? "vi" : "en")
        refreshGeneral()
    }

    @objc private func methodChanged(_ sender: NSSegmentedControl) {
        guard !isSyncing else { return }
        AppDelegate.shared?.setMethod(sender.selectedSegment == 0 ? "telex" : "vni")
        refreshGeneral()
    }

    @objc private func toneStyleChanged(_ sender: NSSegmentedControl) {
        guard !isSyncing else { return }
        AppDelegate.shared?.setToneStyle(sender.selectedSegment == 0 ? "modern" : "traditional")
        refreshGeneral()
    }

    @objc private func smartChanged(_ sender: NSSwitch) {
        guard !isSyncing else { return }
        AppDelegate.shared?.setSmartEnglish(sender.state == .on)
        refreshGeneral()
    }

    @objc private func insertModeChanged(_ sender: NSSegmentedControl) {
        guard !isSyncing else { return }
        AppDelegate.shared?.setInsertMode(sender.selectedSegment == 0 ? .marked : .direct)
        refreshGeneral()
    }

    // MARK: Compatibility mode actions

    @objc private func compatModeChanged(_ sender: NSSwitch) {
        guard !isSyncing, let delegate = AppDelegate.shared else { return }
        let enabled = sender.state == .on
        delegate.setCompatibilityMode(enabled)
        // First enable without permission: trigger the system prompt once, then
        // guide the user with the status line (never crash if the tap fails).
        if enabled, !delegate.compatibilityStatus.permissionGranted {
            delegate.requestCompatibilityPermission()
        }
        refreshGeneral()
    }

    @objc private func grantAccessibilityTapped(_ sender: Any?) {
        guard let delegate = AppDelegate.shared else { return }
        delegate.requestCompatibilityPermission()
        delegate.retryCompatibilityTap()
        refreshGeneral()
    }

    @objc private func openAccessibilitySettingsTapped(_ sender: Any?) {
        guard let delegate = AppDelegate.shared else { return }
        if !delegate.openCompatibilityAccessibilitySettings() {
            let alert = NSAlert()
            alert.messageText = "Không mở được System Settings"
            alert.informativeText = "Hãy mở thủ công: System Settings → Privacy & Security → Accessibility, rồi bật DoctKey."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        refreshGeneral()
    }

    @objc private func recheckCompatibilityTapped(_ sender: Any?) {
        AppDelegate.shared?.retryCompatibilityTap()
        refreshGeneral()
    }

    @objc private func launchAtLoginChanged(_ sender: NSSwitch) {
        guard !isSyncing, let delegate = AppDelegate.shared else { return }
        let wanted = sender.state == .on
        // setLaunchAtLogin refreshes the window itself, so show the failure after
        // that refresh or the state text would overwrite the reason.
        let error = delegate.setLaunchAtLogin(wanted)
        refreshGeneral()
        if let error {
            launchAtLoginStatusLabel.stringValue = "Không đổi được trạng thái khởi động cùng macOS: \(error)"
            launchAtLoginStatusLabel.textColor = .systemRed
        }
    }

    private func refreshGeneral() {
        guard let delegate = AppDelegate.shared else { return }
        isSyncing = true
        defer { isSyncing = false }
        let state = delegate.menuState
        modeControl.selectedSegment = state.mode == "vi" ? 0 : 1
        methodControl.selectedSegment = state.method == "vni" ? 1 : 0
        toneControl.selectedSegment = state.toneStyle == "traditional" ? 1 : 0
        smartSwitch.state = state.smartEnglish ? .on : .off
        insertControl.selectedSegment = state.insertMode == .direct ? 1 : 0
        generalConfigPathLabel.stringValue = "Cấu hình: \(delegate.configFilePath)"
        generalConfigPathLabel.toolTip = delegate.configFilePath

        // Compatibility mode (CGEvent tap): switch + status + permission actions.
        let compatibility = delegate.compatibilityStatus
        compatSwitch.state = delegate.config.compatMode ? .on : .off
        compatStatusLabel.stringValue = compatibility.displayText
        compatStatusLabel.textColor = color(for: compatibility.tone)
        compatPermissionButton.isEnabled = !compatibility.permissionGranted
        compatRecheckButton.isEnabled = delegate.config.compatMode && !compatibility.running

        // Launch at login (SMAppService is the source of truth).
        let loginState = delegate.launchAtLoginState
        launchAtLoginSwitch.state = loginState.isRegistered ? .on : .off
        launchAtLoginStatusLabel.stringValue = LaunchAtLoginText.displayText(for: loginState)
        launchAtLoginStatusLabel.textColor = color(for: LaunchAtLoginText.tone(for: loginState))
        launchAtLoginHintLabel.isHidden = !AppInstallation.isRepositoryBuild(path: delegate.runningBundlePath)
    }

    /// Maps a status tone to the AppKit colour used by the settings rows.
    private func color(for tone: StatusTone) -> NSColor {
        switch tone {
        case .success: return .systemGreen
        case .warning: return .systemOrange
        case .danger: return .systemRed
        case .neutral: return .secondaryLabelColor
        }
    }

    // MARK: - Hotkeys tab

    private func buildHotkeysTab() -> NSView {
        var rows: [NSView] = []
        for field in Config.hotkeyFieldOrder {
            let title = Config.hotkeyFieldTitles[field] ?? field
            let titleLabel = makeLabel(title, size: 12)
            titleLabel.widthAnchor.constraint(equalToConstant: 190).isActive = true

            let fieldView = NSTextField(string: "")
            fieldView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            fieldView.isEditable = true
            fieldView.isBezeled = true
            fieldView.placeholderString = "ctrl+alt+v"
            fieldView.widthAnchor.constraint(equalToConstant: 160).isActive = true
            fieldView.target = self
            fieldView.action = #selector(hotkeyFieldSubmitted(_:))
            hotkeyFields[field] = fieldView

            let errorLabel = wrappingLabel("", size: 11, color: .systemRed)
            errorLabel.isHidden = true
            hotkeyErrorLabels[field] = errorLabel

            let row = NSStackView(views: [titleLabel, fieldView, errorLabel])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.distribution = .fill
            rows.append(row)
        }

        hotkeyStatusLabel = wrappingLabel("", size: 11, color: .secondaryLabelColor)

        let applyButton = button("Áp dụng", action: #selector(applyHotkeysTapped(_:)))
        applyButton.bezelColor = .controlAccentColor
        let defaultsButton = button("Khôi phục mặc định", action: #selector(resetHotkeysTapped(_:)))

        let stack = verticalStack([
            sectionLabel("Phím tắt toàn cục"),
            wrappingLabel("Phím tắt hoạt động trong mọi ứng dụng. Dạng hợp lệ: ctrl+alt+v, cmd+shift+1… cần ít nhất một phím bổ trợ (ctrl, alt, cmd hoặc shift).",
                          size: 11,
                          color: .secondaryLabelColor),
            separator()
        ] + rows + [
            separator(),
            horizontalStack([applyButton, defaultsButton, hotkeyStatusLabel])
        ])
        return stack
    }

    @objc private func hotkeyFieldSubmitted(_ sender: NSTextField) {
        applyHotkeysTapped(sender)
    }

    @objc private func applyHotkeysTapped(_ sender: Any?) {
        guard !installInProgress else { return }
        applyHotkeyFields()
    }

    @objc private func resetHotkeysTapped(_ sender: Any?) {
        guard !isSyncing else { return }
        for field in Config.hotkeyFieldOrder {
            hotkeyFields[field]?.stringValue = Config.defaultHotkeys[field] ?? ""
        }
        applyHotkeyFields()
    }

    private func applyHotkeyFields() {
        guard let delegate = AppDelegate.shared else { return }
        var specs: [String: String] = [:]
        for field in Config.hotkeyFieldOrder {
            specs[field] = hotkeyFields[field]?.stringValue ?? ""
        }

        let errors = Config.validateHotkeys(specs)
        for field in Config.hotkeyFieldOrder {
            let error = errors[field]
            hotkeyErrorLabels[field]?.stringValue = error ?? ""
            hotkeyErrorLabels[field]?.isHidden = (error == nil)
        }
        guard errors.isEmpty else {
            hotkeyStatusLabel.stringValue = "Chưa áp dụng — hãy sửa các phím tắt không hợp lệ."
            hotkeyStatusLabel.textColor = .systemRed
            return
        }

        let registered = delegate.applyHotkeys(specs)
        refreshHotkeys()
        let total = Config.hotkeyFieldOrder.count
        if registered == total {
            hotkeyStatusLabel.stringValue = "Đã áp dụng \(registered)/\(total) phím tắt."
            hotkeyStatusLabel.textColor = .systemGreen
        } else {
            hotkeyStatusLabel.stringValue = "Đã lưu \(total) phím tắt nhưng chỉ đăng ký được \(registered)/\(total) tổ hợp — một số tổ hợp có thể đang bị ứng dụng khác chiếm dụng."
            hotkeyStatusLabel.textColor = .systemOrange
        }
    }

    private func refreshHotkeys() {
        guard let delegate = AppDelegate.shared else { return }
        isSyncing = true
        defer { isSyncing = false }
        for field in Config.hotkeyFieldOrder {
            hotkeyFields[field]?.stringValue = delegate.config.hotkeys[field] ?? ""
            hotkeyErrorLabels[field]?.stringValue = ""
            hotkeyErrorLabels[field]?.isHidden = true
        }
    }

    // MARK: - Status tab

    private func buildStatusTab() -> NSView {
        statusStateLabel = makeLabel("", size: 15, weight: .semibold)
        statusHintLabel = wrappingLabel("", size: 12, color: .secondaryLabelColor)

        sourceSummaryLabel = detailValueLabel()
        installedPathLabel = detailValueLabel()
        runningPathLabel = detailValueLabel()
        versionLabel = detailValueLabel(selectable: false)
        signatureLabel = detailValueLabel(selectable: false)
        identitiesLabel = detailValueLabel(selectable: false)
        configPathLabel = detailValueLabel()

        buildWarningLabel = wrappingLabel("", size: 11, color: .systemOrange)
        let warningCTA = button("Cài / cập nhật vào hệ thống…", action: #selector(installTapped(_:)))
        let warningRow = NSStackView(views: [buildWarningLabel, warningCTA])
        warningRow.orientation = .horizontal
        warningRow.alignment = .centerY
        warningRow.spacing = 10
        warningRow.distribution = .fill
        buildWarningRow = warningRow
        buildWarningRow.isHidden = true

        refreshButton = button("Kiểm tra lại", action: #selector(refreshStatusTapped(_:)))
        registerButton = button("Đăng ký bộ gõ", action: #selector(registerTapped(_:)))
        enableButton = button("Bật", action: #selector(enableTapped(_:)))
        selectButton = button("Chọn", action: #selector(selectTapped(_:)))

        let systemSettingsButton = button("Mở System Settings → Input Sources",
                                          action: #selector(openSystemSettingsTapped(_:)))

        signingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        signingPopup.addItem(withTitle: "Ad-hoc (mặc định)")
        signingPopup.target = self
        signingPopup.action = #selector(signingIdentityChanged(_:))
        signingPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        signingHintLabel = wrappingLabel("", size: 11, color: .secondaryLabelColor)
        signingHintLabel.stringValue = "Nếu macOS chặn bộ gõ: tạo chứng chỉ Apple Development miễn phí trong Xcode → Settings → Accounts → Manage Certificates, rồi chọn chứng chỉ đó ở đây để ký lại."
        let xcodeButton = button("Mở Xcode", action: #selector(openXcodeTapped(_:)))

        installButton = button("Cài / cập nhật vào hệ thống…", action: #selector(installTapped(_:)))
        installButton.bezelColor = .controlAccentColor
        uninstallButton = button("Gỡ cài đặt…", action: #selector(uninstallTapped(_:)))

        actionStatusLabel = wrappingLabel("", size: 11, color: .secondaryLabelColor)

        let copyDiagnosticsButton = button("Sao chép chẩn đoán", action: #selector(copyDiagnosticsTapped(_:)))

        let stack = verticalStack([
            sectionLabel("Trạng thái bộ gõ"),
            statusStateLabel,
            statusHintLabel,
            separator(),
            sectionLabel("Nguồn nhập & hệ thống"),
            detailRow("Nguồn nhập:", value: sourceSummaryLabel),
            detailRow("Đường dẫn cài đặt:", value: installedPathLabel),
            detailRow("Đang chạy từ:", value: runningPathLabel),
            detailRow("Phiên bản:", value: versionLabel),
            detailRow("Chữ ký:", value: signatureLabel),
            detailRow("Chứng chỉ:", value: identitiesLabel),
            detailRow("Cấu hình:", value: configPathLabel),
            buildWarningRow,
            horizontalStack([refreshButton, registerButton, enableButton, selectButton]),
            horizontalStack([systemSettingsButton]),
            separator(),
            sectionLabel("Cài đặt / cập nhật"),
            controlRow("Ký bằng:", control: signingPopup),
            signingHintLabel,
            horizontalStack([xcodeButton, installButton]),
            horizontalStack([uninstallButton]),
            separator(),
            sectionLabel("Nếu DoctKey chưa xuất hiện trong System Settings"),
            wrappingLabel(SettingsStatusText.threeStepInstructions, size: 11, color: .secondaryLabelColor),
            separator(),
            horizontalStack([copyDiagnosticsButton, actionStatusLabel])
        ])
        return stack
    }

    @objc private func refreshStatusTapped(_ sender: Any?) {
        refreshStatus(deep: true)
        setActionStatus("Đã kiểm tra lại lúc \(SettingsWindowController.timeFormatter.string(from: Date())).", color: .secondaryLabelColor)
    }

    @objc private func registerTapped(_ sender: Any?) {
        guard let delegate = AppDelegate.shared else { return }
        let path = latestSnapshot?.installedPath ?? delegate.runningBundlePath
        let status = InputSourceManager.registerInputSource(bundlePath: path)
        refreshStatus(deep: true)
        if status == noErr {
            setActionStatus("TISRegisterInputSource: noErr (0). Nếu vẫn chưa thấy bộ gõ, hãy đăng xuất/đăng nhập lại.", color: .systemGreen)
        } else {
            setActionStatus("TISRegisterInputSource thất bại (OSStatus \(status)). Hãy thử đăng xuất/đăng nhập lại rồi bấm lại.", color: .systemOrange)
        }
    }

    @objc private func enableTapped(_ sender: Any?) {
        let statuses = InputSourceManager.enableInputSources()
        refreshStatus(deep: true)
        if statuses.isEmpty {
            setActionStatus("Chưa có nguồn nhập DoctKey trong hệ thống — hãy đăng xuất/đăng nhập lại hoặc thêm trong System Settings.", color: .systemOrange)
            return
        }
        if statuses.allSatisfy({ $0 == noErr }) {
            setActionStatus("Đã bật \(statuses.count) nguồn nhập DoctKey.", color: .systemGreen)
        } else {
            setActionStatus("Bật nguồn nhập: có lỗi OSStatus \(statuses.filter { $0 != noErr }).", color: .systemOrange)
        }
    }

    @objc private func selectTapped(_ sender: Any?) {
        guard let status = InputSourceManager.selectFirstInputSource() else {
            setActionStatus("Chưa có nguồn nhập DoctKey để chọn — hãy đăng xuất/đăng nhập lại sau khi cài.", color: .systemOrange)
            return
        }
        refreshStatus(deep: true)
        if status == noErr {
            setActionStatus("Đã chuyển sang nguồn nhập DoctKey.", color: .systemGreen)
        } else {
            setActionStatus("TISSelectInputSource thất bại (OSStatus \(status)).", color: .systemOrange)
        }
    }

    @objc private func openSystemSettingsTapped(_ sender: Any?) {
        if !InputSourceManager.openKeyboardInputSourcesSettings() {
            let alert = NSAlert()
            alert.messageText = "Không mở được System Settings"
            alert.informativeText = "Hãy mở thủ công: System Settings → Keyboard → Input Sources, bấm “+” và chọn DoctKey."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func openXcodeTapped(_ sender: Any?) {
        if !InputSourceManager.openXcode() {
            let alert = NSAlert()
            alert.messageText = "Không tìm thấy Xcode"
            alert.informativeText = "Cài Xcode từ App Store, sau đó mở Xcode → Settings → Accounts → Manage Certificates → “+” → Apple Development. Quay lại đây và chọn chứng chỉ để ký lại DoctKey."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func signingIdentityChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < signingOptions.count else {
            selectedSigningIdentity = nil
            return
        }
        selectedSigningIdentity = signingOptions[index]
    }

    private func refreshSigningPopup(_ identities: [SigningIdentity]) {
        let previous = selectedSigningIdentity
        signingOptions = [nil] + identities.map { Optional($0) }
        signingPopup.removeAllItems()
        signingPopup.addItem(withTitle: "Ad-hoc (mặc định)")
        for identity in identities {
            let suffix = identity.isValid ? "" : " (không hợp lệ)"
            signingPopup.addItem(withTitle: "\(identity.displayName)\(suffix)")
        }
        if let previous,
           let index = signingOptions.firstIndex(where: { $0?.codesignArgument == previous.codesignArgument }) {
            signingPopup.selectItem(at: index)
            selectedSigningIdentity = previous
        } else {
            signingPopup.selectItem(at: 0)
            selectedSigningIdentity = nil
        }
    }

    private func refreshStatus(deep: Bool) {
        guard let delegate = AppDelegate.shared else { return }
        let snapshot = InputSourceManager.snapshot(configPath: delegate.configFilePath,
                                                   coreVersion: delegate.core.version)
        latestSnapshot = snapshot
        if deep {
            deepStatusToken += 1
            let token = deepStatusToken
            let path = snapshot.installedPath ?? snapshot.runningPath
            if latestSignature == nil {
                signatureLabel.stringValue = "Đang kiểm tra…"
                identitiesLabel.stringValue = "Đang kiểm tra…"
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let signature = InputSourceManager.signatureDescription(forBundleAt: path)
                let identities = InputSourceManager.signingIdentities()
                DispatchQueue.main.async {
                    guard let self, self.deepStatusToken == token else { return }
                    self.latestSignature = signature
                    self.latestIdentities = identities
                    self.signatureLabel.stringValue = signature.displayText
                    self.identitiesLabel.stringValue = SigningIdentityParser.summary(identities)
                    self.refreshSigningPopup(identities)
                }
            }
        }

        let state = snapshot.state
        statusStateLabel.stringValue = "Trạng thái: \(state.displayText)"
        switch state.tone {
        case .success: statusStateLabel.textColor = .systemGreen
        case .warning: statusStateLabel.textColor = .systemOrange
        case .danger: statusStateLabel.textColor = .systemRed
        case .neutral: statusStateLabel.textColor = .labelColor
        }
        statusHintLabel.stringValue = SettingsStatusText.hint(for: state)
        switch state.tone {
        case .success: statusHintLabel.textColor = .systemGreen
        case .warning: statusHintLabel.textColor = .systemOrange
        case .danger: statusHintLabel.textColor = .systemRed
        case .neutral: statusHintLabel.textColor = .secondaryLabelColor
        }

        sourceSummaryLabel.stringValue = SettingsStatusText.sourceSummary(sourceCount: snapshot.sourceCount,
                                                                          enabledCount: snapshot.enabledCount,
                                                                          selectedCount: snapshot.selectedCount)
        installedPathLabel.stringValue = snapshot.installedPath ?? "Chưa cài vào hệ thống"
        installedPathLabel.toolTip = snapshot.installedPath
        runningPathLabel.stringValue = snapshot.runningPath
        runningPathLabel.toolTip = snapshot.runningPath
        versionLabel.stringValue = "\(snapshot.appVersion) (lõi Rust \(snapshot.coreVersion))"
        configPathLabel.stringValue = snapshot.configPath
        configPathLabel.toolTip = snapshot.configPath

        if let signature = latestSignature {
            signatureLabel.stringValue = signature.displayText
            identitiesLabel.stringValue = SigningIdentityParser.summary(latestIdentities)
        } else if !deep {
            identitiesLabel.stringValue = SigningIdentityParser.summary(latestIdentities)
        }

        if let warning = snapshot.runningFromBuildWarning {
            buildWarningLabel.stringValue = warning
            buildWarningRow.isHidden = false
        } else {
            buildWarningRow.isHidden = true
        }

        registerButton.isEnabled = snapshot.installedPath != nil
        enableButton.isEnabled = snapshot.sourceCount > 0
        selectButton.isEnabled = snapshot.sourceCount > 0
        uninstallButton.isEnabled = snapshot.installedPath != nil && !installInProgress
        let installTitle = snapshot.installedPath != nil && !snapshot.runningFromRepositoryBuild
            ? "Cài đặt lại vào hệ thống…"
            : "Cài / cập nhật vào hệ thống…"
        installButton.title = installTitle
        installButton.isEnabled = !installInProgress
        signingPopup.isEnabled = !installInProgress
    }

    private func setActionStatus(_ text: String, color: NSColor) {
        actionStatusLabel.stringValue = text
        actionStatusLabel.textColor = color
    }

    // MARK: - Install / uninstall

    @objc private func installTapped(_ sender: Any?) {
        guard !installInProgress else { return }
        installInProgress = true
        refreshStatus(deep: false)
        setActionStatus("Đang cài đặt… (nhập mật khẩu quản trị nếu macOS hỏi)", color: .secondaryLabelColor)

        let identity = selectedSigningIdentity
        InputSourceManager.install(signingIdentity: identity) { [weak self] result, log in
            guard let self else { return }
            self.installInProgress = false
            self.refreshStatus(deep: true)
            if !log.isEmpty { NSLog("DoctKey install log:\n%@", log) }
            switch result {
            case .success(let path):
                self.setActionStatus(SettingsStatusText.installSuccessHint(path: path), color: .systemGreen)
                let alert = NSAlert()
                alert.messageText = "Đã cài DoctKey"
                alert.informativeText = SettingsStatusText.installSuccessHint(path: path)
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            case .cancelled:
                self.setActionStatus("Đã huỷ cài đặt — cấu hình và bản cài hiện tại không thay đổi.", color: .secondaryLabelColor)
            case .failed(let message):
                self.setActionStatus(message, color: .systemRed)
                let alert = NSAlert()
                alert.messageText = "Cài đặt thất bại"
                alert.informativeText = message
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    @objc private func uninstallTapped(_ sender: Any?) {
        guard !installInProgress, let snapshot = latestSnapshot else { return }
        let installedPaths = [AppInstallation.systemBundlePath(), AppInstallation.userBundlePath()]
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard !installedPaths.isEmpty else {
            setActionStatus("Không tìm thấy bản cài đặt nào để gỡ.", color: .secondaryLabelColor)
            return
        }

        let confirm = NSAlert()
        confirm.messageText = "Gỡ cài đặt DoctKey?"
        confirm.informativeText = """
        DoctKey.app sẽ bị xoá khỏi hệ thống (\(installedPaths.joined(separator: ", "))).
        File cấu hình \(snapshot.configPath) vẫn được giữ lại.

        Bạn cũng cần xoá DoctKey trong System Settings → Keyboard → Input Sources sau khi gỡ.
        """
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Gỡ cài đặt")
        confirm.addButton(withTitle: "Huỷ")
        confirm.buttons.first?.hasDestructiveAction = true
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        installInProgress = true
        refreshStatus(deep: false)
        setActionStatus("Đang gỡ cài đặt… (nhập mật khẩu quản trị nếu macOS hỏi)", color: .secondaryLabelColor)
        InputSourceManager.terminateOtherInstances()

        let runningFromInstalled = AppInstallation.isInstalledPath(Bundle.main.bundleURL.path)
        InputSourceManager.uninstall { [weak self] result, log in
            guard let self else { return }
            self.installInProgress = false
            self.refreshStatus(deep: true)
            if !log.isEmpty { NSLog("DoctKey uninstall log:\n%@", log) }
            switch result {
            case .success:
                self.setActionStatus("Đã gỡ DoctKey. Cấu hình vẫn được giữ lại.", color: .secondaryLabelColor)
                let alert = NSAlert()
                alert.messageText = "Đã gỡ cài đặt DoctKey"
                alert.informativeText = SettingsStatusText.uninstallHint
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
                if runningFromInstalled {
                    NSApp.terminate(nil)
                }
            case .cancelled:
                self.setActionStatus("Đã huỷ gỡ cài đặt.", color: .secondaryLabelColor)
            case .failed(let message):
                self.setActionStatus(message, color: .systemRed)
                let alert = NSAlert()
                alert.messageText = "Gỡ cài đặt thất bại"
                alert.informativeText = message
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    // MARK: - Diagnostics

    @objc private func copyDiagnosticsTapped(_ sender: Any?) {
        guard let delegate = AppDelegate.shared else { return }
        let snapshot = latestSnapshot ?? InputSourceManager.snapshot(configPath: delegate.configFilePath,
                                                                     coreVersion: delegate.core.version)
        if let signature = latestSignature {
            let report = DiagnosticsReport.build(snapshot.diagnosticsInfo(signature: signature,
                                                                         identities: latestIdentities))
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(report, forType: .string)
            NSLog("DoctKey: diagnostics copied to the clipboard")
            setActionStatus("Đã sao chép chẩn đoán vào clipboard — dán vào báo cáo cho người phát triển.", color: .systemGreen)
            return
        }

        setActionStatus("Đang thu thập thông tin chẩn đoán…", color: .secondaryLabelColor)
        let path = snapshot.installedPath ?? snapshot.runningPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let signature = InputSourceManager.signatureDescription(forBundleAt: path)
            let identities = InputSourceManager.signingIdentities()
            let report = DiagnosticsReport.build(snapshot.diagnosticsInfo(signature: signature,
                                                                         identities: identities))
            DispatchQueue.main.async {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(report, forType: .string)
                NSLog("DoctKey: diagnostics copied to the clipboard")
                guard let self else { return }
                self.latestSnapshot = snapshot
                self.latestSignature = signature
                self.latestIdentities = identities
                self.signatureLabel.stringValue = signature.displayText
                self.identitiesLabel.stringValue = SigningIdentityParser.summary(identities)
                self.refreshSigningPopup(identities)
                self.setActionStatus("Đã sao chép chẩn đoán vào clipboard — dán vào báo cáo cho người phát triển.", color: .systemGreen)
            }
        }
    }

    // MARK: - About tab

    private func buildAboutTab() -> NSView {
        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 64).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 64).isActive = true

        aboutVersionLabel = makeLabel("", size: 20, weight: .bold)
        aboutCoreLabel = wrappingLabel("", size: 12, color: .secondaryLabelColor)
        aboutPathsLabel = wrappingLabel("", size: 11, color: .secondaryLabelColor)
        aboutConfigLabel = wrappingLabel("", size: 11, color: .secondaryLabelColor)
        aboutHotkeysLabel = wrappingLabel("", size: 11, color: .labelColor)

        let stack = verticalStack([
            horizontalStack([iconView, aboutVersionLabel]),
            aboutCoreLabel,
            separator(),
            aboutPathsLabel,
            aboutConfigLabel,
            separator(),
            sectionLabel("Phím tắt mặc định"),
            aboutHotkeysLabel,
            separator(),
            wrappingLabel("DoctKey là bộ gõ tiếng Việt + tiếng Anh cho macOS: lõi xử lý viết bằng Rust, giao diện InputMethodKit. Xem README.md trong thư mục repo để biết hướng dẫn đầy đủ.",
                          size: 11,
                          color: .secondaryLabelColor),
            horizontalStack([
                button("Mở file cấu hình", action: #selector(openConfigTapped(_:))),
                button("Thoát DoctKey", action: #selector(quitTapped(_:)))
            ])
        ])
        return stack
    }

    private func refreshAbout() {
        guard let delegate = AppDelegate.shared else { return }
        aboutVersionLabel.stringValue = "DoctKey \(delegate.appVersion)"
        aboutCoreLabel.stringValue = "Lõi xử lý Rust \(delegate.core.version) · Chế độ \(delegate.config.mode == "vi" ? "Tiếng Việt" : "English") · \(delegate.menuState.methodName)"
        let installed = AppInstallation.installedBundlePath() ?? "(chưa cài vào hệ thống)"
        aboutPathsLabel.stringValue = "Đang chạy từ: \(delegate.runningBundlePath)\nĐã cài trong hệ thống: \(installed)"
        aboutConfigLabel.stringValue = "File cấu hình: \(delegate.configFilePath)"
        let hotkeys = Config.hotkeyFieldOrder.map { field -> String in
            let title = Config.hotkeyFieldTitles[field] ?? field
            let spec = delegate.config.hotkeys[field] ?? ""
            return "\(Config.formatHotkey(spec)) — \(title)"
        }
        aboutHotkeysLabel.stringValue = hotkeys.joined(separator: "\n")
    }

    // MARK: - Shared actions

    @objc private func openConfigTapped(_ sender: Any?) {
        AppDelegate.shared?.openConfig()
    }

    @objc private func reloadConfigTapped(_ sender: Any?) {
        AppDelegate.shared?.reloadConfig()
        setActionStatus("Đã nạp lại cấu hình.", color: .secondaryLabelColor)
    }

    @objc private func quitTapped(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    // MARK: - View helpers

    private func verticalStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func horizontalStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func controlRow(_ title: String, control: NSView) -> NSStackView {
        let titleLabel = makeLabel(title, size: 13)
        titleLabel.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [titleLabel, control, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.distribution = .fill
        return row
    }

    private func detailRow(_ title: String, value: NSTextField) -> NSStackView {
        let keyLabel = makeLabel(title, size: 12, color: .secondaryLabelColor)
        keyLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let row = NSStackView(views: [keyLabel, value])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.distribution = .fill
        return row
    }

    private func detailValueLabel(selectable: Bool = true) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.isSelectable = selectable
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        makeLabel(text, size: 13, weight: .semibold)
    }

    private func makeLabel(_ text: String,
                           size: CGFloat,
                           weight: NSFont.Weight = .regular,
                           color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        return label
    }

    private func wrappingLabel(_ text: String,
                               size: CGFloat,
                               color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size)
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 580
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }
}

/// Document view for the scroll views: flipped so content starts at the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension SettingsWindowController: NSTabViewDelegate {
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let raw = tabViewItem?.identifier as? Int,
              let tab = SettingsTab(rawValue: raw) else { return }
        switch tab {
        case .general: refreshGeneral()
        case .hotkeys: refreshHotkeys()
        case .status: refreshStatus(deep: latestSignature == nil)
        case .about: refreshAbout()
        }
    }
}
