import Darwin
import Foundation

// Pure, AppKit-free helpers used by the settings window, the AppDelegate and the
// test runner. Everything in this file is deterministic and headless-testable:
// launch policy, input-source status text, install-path detection, signing
// output parsing, diagnostics text and the privileged-install command builder.

// MARK: - Cross-process notifications

enum DoctKeyNotifications {
    /// Distributed notification posted by a settings-only process after it has
    /// persisted the config. The IME process keeps its own `Config`/engine
    /// instance, so it must reload the file when another process edits it.
    static let configChangedName = "com.doct.doctkey.configChanged"
    static var configChanged: Notification.Name { Notification.Name(configChangedName) }
}

// MARK: - Launch context

/// What a settings-window decision should be for the current process.
enum SettingsLaunchDecision: Equatable {
    /// Explicit user request (`--settings`): show the window right away.
    case showImmediately
    /// Likely a Finder double-click: show the window only once macOS activates
    /// the app, so an IME launch (which never activates) stays headless.
    case showWhenActivated
    /// Never show a window automatically.
    case never
}

/// How this process was started, used to avoid popping a window when macOS
/// launches the app as an input method.
///
/// Heuristic (documented in README):
///  * `--settings` → explicit request, always show.
///  * a parent process named `imklaunchagent` → InputMethodKit launch, never show.
///  * any other command-line argument → a CLI helper or explicit user command,
///    never show.
///  * no arguments at all → Finder double-click; show once the app is activated.
struct LaunchContext {
    let arguments: [String]
    let forceSettings: Bool
    let parentProcessPaths: [String]

    /// Reads the live launch context of the current process.
    static func current(arguments: [String] = CommandLine.arguments) -> LaunchContext {
        LaunchContext(arguments: arguments,
                      forceSettings: arguments.contains("--settings"),
                      parentProcessPaths: parentProcessChain())
    }

    /// True when InputMethodKit's launcher is anywhere in the parent chain.
    var wasLaunchedByInputMethodKit: Bool {
        parentProcessPaths.contains { path in
            (path as NSString).lastPathComponent == "imklaunchagent"
        }
    }

    /// A plain Finder double-click passes no arguments at all.
    var hasNoArguments: Bool { arguments.count <= 1 }

    var launchDecision: SettingsLaunchDecision {
        if forceSettings { return .showImmediately }
        if wasLaunchedByInputMethodKit { return .never }
        if !hasNoArguments { return .never }
        return .showWhenActivated
    }

    // MARK: Process tree (libproc/sysctl)

    /// Paths of the parent processes, closest first (max `limit` entries).
    static func parentProcessChain(limit: Int = 8,
                                   startingAt pid: pid_t = getpid()) -> [String] {
        var chain: [String] = []
        var seen: Set<pid_t> = [pid]
        var current = parentPid(of: pid)
        while chain.count < limit, current > 1, !seen.contains(current) {
            seen.insert(current)
            if let path = processPath(of: current) {
                chain.append(path)
            }
            current = parentPid(of: current)
        }
        return chain
    }

    private static func parentPid(of pid: pid_t) -> pid_t {
        guard pid > 1 else { return 0 }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    private static func processPath(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}

// MARK: - Input-source state

/// Colour/severity of a status line, mapped to `NSColor` by the window.
enum StatusTone: Equatable {
    case success
    case warning
    case danger
    case neutral
}

/// The three states the Status panel can report for our TIS input source.
enum InputSourceState: Equatable {
    case registeredAndEnabled
    case registeredDisabled
    case notRegistered

    static func from(sourceCount: Int, enabledCount: Int) -> InputSourceState {
        if sourceCount <= 0 { return .notRegistered }
        return enabledCount > 0 ? .registeredAndEnabled : .registeredDisabled
    }

    var displayText: String {
        switch self {
        case .registeredAndEnabled: return "Đã đăng ký & bật"
        case .registeredDisabled: return "Đã có trong hệ thống nhưng chưa bật"
        case .notRegistered: return "Chưa được hệ thống nhận"
        }
    }

    var isRegistered: Bool {
        switch self {
        case .registeredAndEnabled, .registeredDisabled: return true
        case .notRegistered: return false
        }
    }

    var isEnabled: Bool { self == .registeredAndEnabled }

    var tone: StatusTone {
        switch self {
        case .registeredAndEnabled: return .success
        case .registeredDisabled: return .warning
        case .notRegistered: return .danger
        }
    }
}

/// Vietnamese text shown by the Status panel. Kept here so it can be unit-tested
/// without building any AppKit view.
enum SettingsStatusText {
    static func sourceSummary(sourceCount: Int, enabledCount: Int, selectedCount: Int) -> String {
        if sourceCount == 0 {
            return "Chưa có nguồn nhập DoctKey trong cơ sở dữ liệu của hệ thống."
        }
        var text = "Nguồn nhập DoctKey: \(sourceCount) nguồn, \(enabledCount) đang bật"
        if selectedCount > 0 { text += ", đang được chọn" }
        return text + "."
    }

    static func hint(for state: InputSourceState) -> String {
        switch state {
        case .registeredAndEnabled:
            return "DoctKey đã sẵn sàng. Chuyển nguồn nhập bằng ⌃Space (hoặc phím tắt nguồn nhập của bạn)."
        case .registeredDisabled:
            return "Bộ gõ đã có trong hệ thống nhưng chưa bật. Nhấn “Bật”, sau đó chọn DoctKey trong System Settings → Keyboard → Input Sources."
        case .notRegistered:
            return "macOS 26 cần đăng xuất/đăng nhập lại sau khi cài thì hệ thống mới nhận bộ gõ. Sau đó mở System Settings → Keyboard → Input Sources → “+” và thêm DoctKey."
        }
    }

    static let threeStepInstructions = """
    1. Cài DoctKey vào hệ thống (nút bên dưới) nếu chưa cài.
    2. Đăng xuất rồi đăng nhập lại (bắt buộc trên macOS 26).
    3. Mở System Settings → Keyboard → Input Sources → “+”, chọn DoctKey; sau đó chuyển nguồn nhập bằng ⌃Space.
    """

    static func installSuccessHint(path: String) -> String {
        "Đã cài DoctKey vào: \(path). Hãy đăng xuất/đăng nhập lại, sau đó mở System Settings → Keyboard → Input Sources → “+” và thêm DoctKey."
    }

    static let uninstallHint = """
    Đã gỡ DoctKey khỏi hệ thống. File cấu hình vẫn được giữ lại. Hệ thống có thể còn hiển thị DoctKey trong Input Sources cho tới khi bạn đăng xuất/đăng nhập lại — hãy xoá mục đó trong System Settings → Keyboard → Input Sources.
    """

    static func runningFromBuildWarning(installedPath: String?) -> String? {
        guard let installedPath else { return nil }
        return "Bạn đang chạy bản build trong thư mục repo nhưng đã có bản DoctKey cài trong hệ thống (\(installedPath)). Hãy dùng bản đã cài hoặc cài/cập nhật lại để tránh hai bản DoctKey chạy cùng lúc."
    }

    static func signatureUnavailableReason() -> String {
        "Không đọc được thông tin chữ ký (bundle có thể chưa được ký)."
    }
}

// MARK: - Installation paths

enum AppInstallation {
    static let appName = "DoctKey.app"
    static let systemDirectory = "/Library/Input Methods"
    static let userDirectorySuffix = "/Library/Input Methods"

    static func systemBundlePath() -> String { systemDirectory + "/" + appName }

    static func userBundlePath(home: String = NSHomeDirectory()) -> String {
        home + userDirectorySuffix + "/" + appName
    }

    /// First installed bundle, system-wide location first (same priority as
    /// scripts/install.sh). `nil` when the app only exists in the repo/build.
    static func installedBundlePath(home: String = NSHomeDirectory(),
                                    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        for path in [systemBundlePath(), userBundlePath(home: home)] where fileExists(path) {
            return path
        }
        return nil
    }

    /// Where "Cài / cập nhật vào hệ thống…" copies the bundle to.
    struct Target: Equatable {
        let directory: String
        let bundlePath: String
        let requiresAdministrator: Bool
    }

    static func target(majorOSVersion: Int, home: String = NSHomeDirectory()) -> Target {
        if majorOSVersion >= 26 {
            return Target(directory: systemDirectory,
                          bundlePath: systemBundlePath(),
                          requiresAdministrator: true)
        }
        let directory = home + userDirectorySuffix
        return Target(directory: directory,
                      bundlePath: directory + "/" + appName,
                      requiresAdministrator: false)
    }

    static func currentMajorOSVersion() -> Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    /// True for the repo build (`<repo>/build/DoctKey.app`), false for both
    /// installation locations.
    static func isRepositoryBuild(path: String) -> Bool {
        path.contains("/build/DoctKey.app")
    }

    static func isInstalledPath(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        path == systemBundlePath() || path == userBundlePath(home: home)
    }

    /// Warning shown when a repo build copy is running while a system copy exists.
    static func runningFromBuildWarning(runningPath: String, installedPath: String?) -> String? {
        guard installedPath != nil, isRepositoryBuild(path: runningPath) else { return nil }
        return SettingsStatusText.runningFromBuildWarning(installedPath: installedPath)
    }
}

// MARK: - Privileged install commands

enum InstallResult: Equatable {
    case success(String)      // installed bundle path
    case cancelled            // user dismissed the administrator dialog
    case failed(String)       // human-readable reason
}

enum PrivilegedInstaller {
    /// Single-quotes a value for `/bin/sh`, escaping embedded single quotes.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a value for use inside an AppleScript double-quoted string.
    static func appleScriptEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// AppleScript source that runs the given shell commands as an administrator.
    static func administratorScript(forShellCommands commands: [String]) -> String {
        let shell = commands.joined(separator: " && ")
        return "do shell script \"\(appleScriptEscaped(shell))\" with administrator privileges"
    }

    /// Shell commands copying a (already signed) staging bundle into place.
    /// The destination is replaced atomically-enough for an app bundle and the
    /// system location is normalised to root:wheel.
    static func installCommands(sourceBundle: String, target: AppInstallation.Target) -> [String] {
        var commands = [
            "mkdir -p \(shellQuote(target.directory))",
            "rm -rf \(shellQuote(target.bundlePath))",
            "cp -R \(shellQuote(sourceBundle)) \(shellQuote(target.bundlePath))"
        ]
        if target.requiresAdministrator {
            commands.append("chown -R root:wheel \(shellQuote(target.bundlePath))")
            commands.append("chmod -R go+rX \(shellQuote(target.bundlePath))")
        }
        return commands
    }

    static func uninstallCommands(bundlePaths: [String]) -> [String] {
        bundlePaths.map { "rm -rf \(shellQuote($0))" }
    }

    /// `osascript` exits 1 and prints "User canceled. (-128)" when the user
    /// dismisses the administrator prompt; that must never be reported as a
    /// crash or an installation error.
    static func isUserCancellation(exitCode: Int32, stderr: String) -> Bool {
        guard exitCode != 0 else { return false }
        let lowered = stderr.lowercased()
        return lowered.contains("user canceled")
            || lowered.contains("user cancelled")
            || lowered.contains("(-128)")
    }
}

// MARK: - Code signing inspection

/// One code-signing identity reported by `security find-identity`.
struct SigningIdentity: Equatable {
    let displayName: String
    /// SHA-1 hash used as the `codesign --sign` argument; falls back to the name.
    let sha1: String
    let isValid: Bool

    /// Value passed to `codesign --sign`.
    var codesignArgument: String { sha1.isEmpty ? displayName : sha1 }
}

enum SigningIdentityParser {
    /// Parses `security find-identity -v -p codesigning` (and the non-verbose
    /// variant) output. Lines that are not identity rows are ignored, so the
    /// same parser handles both formats and "N valid identities found" footers.
    static func parse(_ output: String) -> [SigningIdentity] {
        var identities: [SigningIdentity] = []
        var seen: Set<String> = []
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  let firstQuote = line.firstIndex(of: "\""),
                  let lastQuote = line.lastIndex(of: "\""),
                  firstQuote < lastQuote else { continue }
            let name = String(line[line.index(after: firstQuote)..<lastQuote])
            guard !name.isEmpty else { continue }

            var prefix = String(line[line.startIndex..<firstQuote])
                .trimmingCharacters(in: .whitespaces)
            if let closeParen = prefix.range(of: ")", options: .backwards) {
                prefix = String(prefix[prefix.index(after: closeParen.lowerBound)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            let hash = prefix.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .last
                .map(String.init) ?? ""
            let suffix = String(line[line.index(after: lastQuote)...])
            let invalid = suffix.uppercased().contains("CSSMERR")
                || suffix.lowercased().contains("invalid")
            let identity = SigningIdentity(displayName: name,
                                           sha1: hash.isEmpty ? name : hash,
                                           isValid: !invalid)
            if seen.insert(identity.codesignArgument).inserted {
                identities.append(identity)
            }
        }
        return identities
    }

    static func summary(_ identities: [SigningIdentity]) -> String {
        if identities.isEmpty {
            return "Chưa có chứng chỉ ký mã trong keychain (chỉ dùng được ad-hoc)."
        }
        let valid = identities.filter { $0.isValid }.count
        let invalid = identities.count - valid
        if invalid == 0 {
            return "\(valid) chứng chỉ ký mã khả dụng."
        }
        return "\(valid) chứng chỉ ký mã khả dụng, \(invalid) không hợp lệ."
    }
}

/// Parsed `codesign -dv --verbose=2` output.
struct SignatureDescription: Equatable {
    let isAdHoc: Bool
    let isUnsigned: Bool
    let authority: String?
    let teamIdentifier: String?

    static func parse(_ codesignOutput: String) -> SignatureDescription {
        var isAdHoc = false
        var isUnsigned = false
        var authority: String?
        var team: String?
        for rawLine in codesignOutput.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Signature=") {
                isAdHoc = line.dropFirst("Signature=".count).lowercased() == "adhoc"
            } else if line.hasPrefix("Authority="), authority == nil {
                let value = String(line.dropFirst("Authority=".count))
                if !value.isEmpty { authority = value }
            } else if line.hasPrefix("TeamIdentifier=") {
                let value = String(line.dropFirst("TeamIdentifier=".count))
                if value != "not set", !value.isEmpty { team = value }
            } else if line.lowercased().contains("not signed at all") {
                isUnsigned = true
            }
        }
        return SignatureDescription(isAdHoc: isAdHoc,
                                    isUnsigned: isUnsigned,
                                    authority: authority,
                                    teamIdentifier: team)
    }

    var displayText: String {
        if isUnsigned { return "chưa ký" }
        if isAdHoc { return "ad-hoc (chưa có chứng chỉ Apple)" }
        if let authority { return authority }
        return "không xác định"
    }
}

// MARK: - Diagnostics report ("Sao chép chẩn đoán")

struct DiagnosticsInfo {
    var osVersion: String
    var runningPath: String
    var installedPath: String?
    var appVersion: String
    var coreVersion: String
    var configPath: String
    var sourceCount: Int
    var enabledCount: Int
    var selectedCount: Int
    var sourceLines: [String]
    var signature: SignatureDescription
    var identities: [SigningIdentity]
}

enum DiagnosticsReport {
    static func build(_ info: DiagnosticsInfo) -> String {
        var lines: [String] = []
        lines.append("DoctKey diagnostics")
        lines.append("==================")
        lines.append("macOS: \(info.osVersion)")
        lines.append("Phiên bản: \(info.appVersion) (lõi Rust \(info.coreVersion))")
        lines.append("Đang chạy từ: \(info.runningPath)")
        lines.append("Đã cài: \(info.installedPath ?? "(chưa cài vào hệ thống)")")
        lines.append("Bản build repo: \(AppInstallation.isRepositoryBuild(path: info.runningPath) ? "có" : "không")")
        lines.append("Chữ ký: \(info.signature.displayText)")
        if let team = info.signature.teamIdentifier { lines.append("Team: \(team)") }
        lines.append("Chứng chỉ ký mã: \(SigningIdentityParser.summary(info.identities))")
        lines.append("Cấu hình: \(info.configPath)")
        lines.append("")
        lines.append("TIS input sources: \(info.sourceCount) khớp, \(info.enabledCount) bật, \(info.selectedCount) đang chọn")
        for line in info.sourceLines {
            lines.append("  - \(line)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - App info

enum AppInfo {
    static func shortVersion(bundle: Bundle = .main) -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    static func buildVersion(bundle: Bundle = .main) -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }

    static func aboutText(shortVersion: String,
                          coreVersion: String,
                          configPath: String,
                          runningPath: String,
                          installedPath: String?) -> String {
        """
        DoctKey \(shortVersion) — bộ gõ tiếng Việt + tiếng Anh cho macOS.
        Lõi xử lý: Rust \(coreVersion).
        Đang chạy từ: \(runningPath)
        Đã cài trong hệ thống: \(installedPath ?? "(chưa cài)")
        File cấu hình: \(configPath)

        Phím tắt mặc định:
        ⌃⌥V — Tiếng Việt / English
        ⌃⌥T — Telex / VNI
        ⌃⌥D — kiểu đặt dấu
        ⌃⌥E — Smart English
        ⌃⌥R — nạp lại cấu hình

        Xem README.md trong thư mục repo để biết hướng dẫn đầy đủ.
        """
    }
}
