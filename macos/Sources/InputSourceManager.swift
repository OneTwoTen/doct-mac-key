import Carbon
import Cocoa

// Live reading of the system input-source database (Carbon TIS), the on-disk
// installation and code-signing state, plus the privileged install/uninstall
// flows used by the settings window. The pure parts of this file's logic live
// in SettingsHelpers.swift so they can be unit-tested headlessly.

/// Snapshot of everything the Status panel displays.
struct InputSourceSnapshot {
    let sourceCount: Int
    let enabledCount: Int
    let selectedCount: Int
    let installedPath: String?
    let runningPath: String
    let systemCopyExists: Bool
    let userCopyExists: Bool
    let appVersion: String
    let coreVersion: String
    let configPath: String
    /// One `id enabled=… selected=…` line per matching TIS source.
    let sourceLines: [String]

    var state: InputSourceState {
        InputSourceState.from(sourceCount: sourceCount, enabledCount: enabledCount)
    }

    var displayInstalledPath: String { installedPath ?? "Chưa cài vào hệ thống" }

    var runningFromRepositoryBuild: Bool {
        AppInstallation.isRepositoryBuild(path: runningPath)
    }

    var runningFromBuildWarning: String? {
        AppInstallation.runningFromBuildWarning(runningPath: runningPath, installedPath: installedPath)
    }

    func diagnosticsInfo(signature: SignatureDescription,
                         identities: [SigningIdentity]) -> DiagnosticsInfo {
        DiagnosticsInfo(osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                        runningPath: runningPath,
                        installedPath: installedPath,
                        appVersion: appVersion,
                        coreVersion: coreVersion,
                        configPath: configPath,
                        sourceCount: sourceCount,
                        enabledCount: enabledCount,
                        selectedCount: selectedCount,
                        sourceLines: sourceLines,
                        signature: signature,
                        identities: identities)
    }
}

/// Thin wrapper over the Carbon TIS APIs plus the install/uninstall flows.
final class InputSourceManager {
    static let bundleIdentifier = "com.doct.doctkey"
    static let modeIdentifier = InputSourceManager.bundleIdentifier + ".mode"

    // MARK: - TIS queries

    static func allInputSources() -> [TISInputSource] {
        guard let list = TISCreateInputSourceList(nil, true) else { return [] }
        return (list.takeRetainedValue() as NSArray) as? [TISInputSource] ?? []
    }

    static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
    }

    static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        property(source, key) as? String
    }

    static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool? {
        property(source, key) as? Bool
    }

    /// Every TIS source belonging to this app (source id, mode id or bundle id).
    static func matchingInputSources() -> [TISInputSource] {
        matchingInputSources(in: allInputSources())
    }

    static func matchingInputSources(in sources: [TISInputSource]) -> [TISInputSource] {
        let wanted: Set<String> = [bundleIdentifier, modeIdentifier]
        return sources.filter { source in
            if let identifier = stringProperty(source, kTISPropertyInputSourceID),
               wanted.contains(identifier) {
                return true
            }
            if let bundleID = stringProperty(source, kTISPropertyBundleID) {
                return bundleID == bundleIdentifier
            }
            return false
        }
    }

    static func inputSourceIdentifier(_ source: TISInputSource) -> String {
        stringProperty(source, kTISPropertyInputSourceID) ?? "(no id)"
    }

    static func isEnabled(_ source: TISInputSource) -> Bool {
        boolProperty(source, kTISPropertyInputSourceIsEnabled) ?? false
    }

    static func isSelected(_ source: TISInputSource) -> Bool {
        boolProperty(source, kTISPropertyInputSourceIsSelected) ?? false
    }

    static func registerInputSource(bundlePath: String) -> OSStatus {
        TISRegisterInputSource(URL(fileURLWithPath: bundlePath) as CFURL)
    }

    static func enableInputSources() -> [OSStatus] {
        matchingInputSources().map { TISEnableInputSource($0) }
    }

    static func selectFirstInputSource() -> OSStatus? {
        guard let source = matchingInputSources().first else { return nil }
        return TISSelectInputSource(source)
    }

    // MARK: - Snapshot

    static func snapshot(configPath: String, coreVersion: String) -> InputSourceSnapshot {
        let sources = matchingInputSources()
        let enabled = sources.filter(isEnabled).count
        let selected = sources.filter(isSelected).count
        let lines = sources.map { source -> String in
            let id = inputSourceIdentifier(source)
            return "\(id) enabled=\(isEnabled(source) ? 1 : 0) selected=\(isSelected(source) ? 1 : 0)"
        }
        let fileManager = FileManager.default
        return InputSourceSnapshot(sourceCount: sources.count,
                                   enabledCount: enabled,
                                   selectedCount: selected,
                                   installedPath: AppInstallation.installedBundlePath(),
                                   runningPath: Bundle.main.bundleURL.path,
                                   systemCopyExists: fileManager.fileExists(atPath: AppInstallation.systemBundlePath()),
                                   userCopyExists: fileManager.fileExists(atPath: AppInstallation.userBundlePath()),
                                   appVersion: AppInfo.shortVersion(),
                                   coreVersion: coreVersion,
                                   configPath: configPath,
                                   sourceLines: lines)
    }

    // MARK: - Code signing inspection

    @discardableResult
    static func runCommand(_ executable: String, _ arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func signatureDescription(forBundleAt path: String) -> SignatureDescription {
        let result = runCommand("/usr/bin/codesign", ["-dv", "--verbose=2", path])
        return SignatureDescription.parse(result.output)
    }

    static func signingIdentities() -> [SigningIdentity] {
        var identities = SigningIdentityParser.parse(
            runCommand("/usr/bin/security",
                       ["find-identity", "-v", "-p", "codesigning"]).output)
        if identities.isEmpty {
            identities = SigningIdentityParser.parse(
                runCommand("/usr/bin/security",
                           ["find-identity", "-p", "codesigning"]).output)
        }
        return identities
    }

    // MARK: - Install / uninstall

    /// Copies the currently running bundle into the version-appropriate install
    /// directory. The staging copy is re-signed as the current user (so a real
    /// identity from the login keychain can be used) and then moved into place
    /// with administrator rights.
    static func install(signingIdentity: SigningIdentity?,
                        completion: @escaping (InstallResult, String) -> Void) {
        let sourceBundle = Bundle.main.bundleURL.path
        let target = AppInstallation.target(majorOSVersion: AppInstallation.currentMajorOSVersion())

        DispatchQueue.global(qos: .userInitiated).async {
            let stagingRoot = NSTemporaryDirectory() + "doctkey-install-" + UUID().uuidString
            let stagingBundle = stagingRoot + "/" + AppInstallation.appName
            var log = ""
            defer { try? FileManager.default.removeItem(atPath: stagingRoot) }

            func finish(_ result: InstallResult) {
                DispatchQueue.main.async { completion(result, log) }
            }

            do {
                try FileManager.default.createDirectory(atPath: stagingRoot,
                                                        withIntermediateDirectories: true)
                try FileManager.default.copyItem(atPath: sourceBundle, toPath: stagingBundle)
            } catch {
                log = "copy staging failed: \(error)"
                finish(.failed("Không sao chép được bundle: \(error.localizedDescription)"))
                return
            }

            // Sign before the privileged copy: `osascript ... with administrator
            // privileges` runs as root, which cannot see the user's login
            // keychain, so the identity must be applied here.
            let signArgument = signingIdentity?.codesignArgument ?? "-"
            var signingArguments = ["--force", "--deep"]
            if signingIdentity != nil {
                signingArguments += ["--options", "runtime"]
            }
            signingArguments += ["--sign", signArgument, stagingBundle]
            let signResult = runCommand("/usr/bin/codesign", signingArguments)
            log += "codesign --sign \(signArgument): exit=\(signResult.exitCode)\n\(signResult.output)\n"
            guard signResult.exitCode == 0 else {
                finish(.failed("Ký mã thất bại (mã lỗi \(signResult.exitCode)). Hãy kiểm tra chứng chỉ trong Xcode → Settings → Accounts → Manage Certificates."))
                return
            }

            let commands = PrivilegedInstaller.installCommands(sourceBundle: stagingBundle,
                                                               target: target)
            let copyResult: (exitCode: Int32, output: String)
            if target.requiresAdministrator {
                let source = PrivilegedInstaller.administratorScript(forShellCommands: commands)
                copyResult = runCommand("/usr/bin/osascript", ["-e", source])
                if PrivilegedInstaller.isUserCancellation(exitCode: copyResult.exitCode,
                                                          stderr: copyResult.output) {
                    log += "administrator dialog cancelled by user\n"
                    finish(.cancelled)
                    return
                }
            } else {
                copyResult = runCommand("/bin/sh", ["-c", commands.joined(separator: " && ")])
            }
            log += "copy: exit=\(copyResult.exitCode)\n\(copyResult.output)\n"
            guard copyResult.exitCode == 0 else {
                finish(.failed("Không cài được vào \(target.bundlePath) (mã lỗi \(copyResult.exitCode))."))
                return
            }

            // Best effort: ask the installed copy to register/enable itself. On
            // macOS 26 this often only takes effect after a logout/login.
            let installedBinary = target.bundlePath + "/Contents/MacOS/DoctKey"
            if FileManager.default.isExecutableFile(atPath: installedBinary) {
                let register = runCommand(installedBinary, ["--register-input-source"])
                log += "register: exit=\(register.exitCode)\n\(register.output)\n"
                let enable = runCommand(installedBinary, ["--enable-input-source"])
                log += "enable: exit=\(enable.exitCode)\n\(enable.output)\n"
            } else {
                log += "installed binary missing or not executable: \(installedBinary)\n"
            }

            finish(.success(target.bundlePath))
        }
    }

    /// Removes every installed bundle (system-wide and per-user), keeping
    /// `~/.config/doctkey/config.json` untouched.
    static func uninstall(completion: @escaping (InstallResult, String) -> Void) {
        let fileManager = FileManager.default
        let paths = [AppInstallation.systemBundlePath(), AppInstallation.userBundlePath()]
            .filter { fileManager.fileExists(atPath: $0) }
        guard !paths.isEmpty else {
            DispatchQueue.main.async {
                completion(.failed("Không tìm thấy bản cài đặt nào trong hệ thống."), "")
            }
            return
        }
        let commands = PrivilegedInstaller.uninstallCommands(bundlePaths: paths)
        let requiresAdministrator = paths.contains { $0.hasPrefix("/Library/") }

        DispatchQueue.global(qos: .userInitiated).async {
            let scriptResult: (exitCode: Int32, output: String)
            if requiresAdministrator {
                let source = PrivilegedInstaller.administratorScript(forShellCommands: commands)
                scriptResult = runCommand("/usr/bin/osascript", ["-e", source])
                if PrivilegedInstaller.isUserCancellation(exitCode: scriptResult.exitCode,
                                                          stderr: scriptResult.output) {
                    DispatchQueue.main.async { completion(.cancelled, scriptResult.output) }
                    return
                }
            } else {
                scriptResult = runCommand("/bin/sh", ["-c", commands.joined(separator: " && ")])
            }
            DispatchQueue.main.async {
                if scriptResult.exitCode == 0 {
                    completion(.success(paths.first ?? ""), scriptResult.output)
                } else {
                    completion(.failed("Không gỡ được DoctKey (mã lỗi \(scriptResult.exitCode))."), scriptResult.output)
                }
            }
        }
    }

    /// Terminates every other DoctKey process (the IME instance that may keep the
    /// old bundle open) without touching the current settings process.
    static func terminateOtherInstances() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        for application in NSWorkspace.shared.runningApplications {
            guard application.bundleIdentifier == bundleIdentifier,
                  application.processIdentifier != currentPID else { continue }
            application.terminate()
        }
    }

    // MARK: - System integration helpers

    /// Opens System Settings → Keyboard → Input Sources.
    @discardableResult
    static func openKeyboardInputSourcesSettings() -> Bool {
        let candidates = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard?InputSources"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return true
            }
        }
        return false
    }

    /// Opens Xcode (for creating an Apple Development certificate). Returns
    /// false when Xcode is not installed.
    @discardableResult
    static func openXcode() -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url,
                                           configuration: configuration,
                                           completionHandler: nil)
        return true
    }
}
