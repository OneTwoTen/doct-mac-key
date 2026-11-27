import AppKit
import Foundation

/// Checks the public GitHub Releases feed and installs signed DoctKey bundles.
/// Updates are downloaded only after the user accepts them from the menu bar.
final class AutoUpdater {
    enum MenuStatus {
        case checking
        case current
        case available(String)
        case downloading(String)
        case installing(String)
        case failed(String)
    }

    enum CheckResult {
        case current
        case available(String)
        case failed(String)
        case alreadyChecking
    }

    private struct Release: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft
            case prerelease
            case assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    private static let repository = "OneTwoTen/doct-mac-key"
    private static let bundleIdentifier = "com.doct.doctkey"

    private let statusChanged: (MenuStatus) -> Void
    private var isChecking = false
    private var isInstalling = false
    private var latestRelease: Release?
    private var latestAsset: Asset?

    init(statusChanged: @escaping (MenuStatus) -> Void) {
        self.statusChanged = statusChanged
    }

    func checkForUpdates(completion: @escaping (CheckResult) -> Void) {
        guard !isChecking, !isInstalling else {
            completion(.alreadyChecking)
            return
        }

        isChecking = true
        statusChanged(.checking)

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DoctKey-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            let result: CheckResult
            var matchingRelease: Release?
            var matchingAsset: Asset?

            if let error {
                result = .failed("Không kết nối được GitHub: \(error.localizedDescription)")
            } else if let response = response as? HTTPURLResponse, response.statusCode != 200 {
                result = .failed("GitHub trả về mã HTTP \(response.statusCode).")
            } else if let data {
                do {
                    let release = try JSONDecoder().decode(Release.self, from: data)
                    let version = Self.normalizedVersion(release.tagName)
                    let expectedAssetName = "DoctKey-\(version)-macos-arm64.zip"
                    guard !release.draft, !release.prerelease,
                          let asset = release.assets.first(where: { $0.name == expectedAssetName }),
                          Self.isTrustedReleaseURL(asset.browserDownloadURL) else {
                        throw UpdateError.invalidRelease
                    }

                    let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
                    if Self.isVersion(version, newerThan: installedVersion) {
                        matchingRelease = release
                        matchingAsset = asset
                        result = .available(version)
                    } else {
                        result = .current
                    }
                } catch {
                    result = .failed("Không đọc được thông tin bản phát hành: \(error.localizedDescription)")
                }
            } else {
                result = .failed("GitHub không trả về dữ liệu bản phát hành.")
            }

            DispatchQueue.main.async {
                self.isChecking = false
                self.latestRelease = matchingRelease
                self.latestAsset = matchingAsset
                switch result {
                case .current:
                    self.statusChanged(.current)
                case .available(let version):
                    self.statusChanged(.available(version))
                case .failed(let message):
                    self.statusChanged(.failed(message))
                case .alreadyChecking:
                    break
                }
                completion(result)
            }
        }.resume()
    }

    func installAvailableUpdate(completion: @escaping (String?) -> Void) {
        guard !isInstalling, let release = latestRelease, let asset = latestAsset else {
            completion("Chưa có bản cập nhật để cài.")
            return
        }
        guard let installedPath = AppInstallation.installedBundlePath(),
              AppInstallation.isInstalledPath(installedPath),
              !AppInstallation.isRepositoryBuild(path: Bundle.main.bundleURL.path) else {
            completion("Hãy mở DoctKey từ bản đã cài trong hệ thống rồi thử cập nhật.")
            return
        }

        isInstalling = true
        let version = Self.normalizedVersion(release.tagName)
        statusChanged(.downloading(version))

        let workRoot = NSTemporaryDirectory() + "doctkey-update-" + UUID().uuidString
        let zipURL = URL(fileURLWithPath: workRoot).appendingPathComponent(asset.name)

        do {
            try FileManager.default.createDirectory(atPath: workRoot,
                                                   withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        } catch {
            isInstalling = false
            completion("Không tạo được thư mục cập nhật: \(error.localizedDescription)")
            return
        }

        var request = URLRequest(url: asset.browserDownloadURL)
        request.timeoutInterval = 120
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        URLSession.shared.downloadTask(with: request) { [weak self] temporaryURL, response, error in
            guard let self else { return }
            do {
                if let error { throw error }
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      let temporaryURL else {
                    throw UpdateError.downloadFailed
                }
                let size = (try FileManager.default.attributesOfItem(atPath: temporaryURL.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size > 0, size <= 500_000_000 else { throw UpdateError.invalidArchive }
                try FileManager.default.copyItem(at: temporaryURL, to: zipURL)

                let extractResult = Self.runProcess("/usr/bin/ditto", ["-x", "-k", zipURL.path, workRoot])
                guard extractResult.status == 0 else {
                    throw UpdateError.processFailed("Không giải nén được gói cập nhật.")
                }

                let candidatePath = workRoot + "/DoctKey.app"
                try Self.validateBundle(at: candidatePath, expectedVersion: version)
                let currentTeam = try Self.teamIdentifier(at: Bundle.main.bundleURL.path)
                let updateTeam = try Self.teamIdentifier(at: candidatePath)
                guard !currentTeam.isEmpty, currentTeam == updateTeam else {
                    throw UpdateError.signatureMismatch
                }

                DispatchQueue.main.async {
                    self.statusChanged(.installing(version))
                }
                try Self.launchInstaller(source: candidatePath,
                                         target: installedPath,
                                         workRoot: workRoot)
                // The installer terminates this process after it has replaced the bundle.
                // A completion callback is only reached when macOS cancels the admin prompt.
            } catch {
                try? FileManager.default.removeItem(atPath: workRoot)
                DispatchQueue.main.async {
                    self.isInstalling = false
                    let message = error.localizedDescription
                    self.statusChanged(.failed(message))
                    completion(message)
                }
            }
        }.resume()
    }

    private static func validateBundle(at path: String, expectedVersion: String) throws {
        guard let bundle = Bundle(path: path),
              bundle.bundleIdentifier == bundleIdentifier,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              version == expectedVersion,
              FileManager.default.isExecutableFile(atPath: path + "/Contents/MacOS/DoctKey") else {
            throw UpdateError.invalidBundle
        }
        let verification = runProcess("/usr/bin/codesign", ["--verify", "--deep", "--strict", path])
        guard verification.status == 0 else { throw UpdateError.signatureInvalid }
    }

    private static func teamIdentifier(at path: String) throws -> String {
        let result = runProcess("/usr/bin/codesign", ["-dv", "--verbose=4", path])
        let output = result.output
        guard result.status == 0,
              let line = output.components(separatedBy: .newlines).first(where: { $0.hasPrefix("TeamIdentifier=") }) else {
            throw UpdateError.signatureInvalid
        }
        let team = String(line.dropFirst("TeamIdentifier=".count))
        guard !team.isEmpty, team != "not set" else { throw UpdateError.signatureInvalid }
        return team
    }

    private static func launchInstaller(source: String,
                                        target: String,
                                        workRoot: String) throws {
        let backup = target + ".doctkey-backup-" + UUID().uuidString
        let qSource = PrivilegedInstaller.shellQuote(source)
        let qTarget = PrivilegedInstaller.shellQuote(target)
        let qBackup = PrivilegedInstaller.shellQuote(backup)
        let qWorkRoot = PrivilegedInstaller.shellQuote(workRoot)
        let appBinary = target + "/Contents/MacOS/DoctKey"
        let userLaunch = "\(PrivilegedInstaller.shellQuote(appBinary)) --register-input-source >/dev/null 2>&1 || true; \(PrivilegedInstaller.shellQuote(appBinary)) --enable-input-source >/dev/null 2>&1 || true; /usr/bin/open -a \(qTarget)"

        var commands = [
            "/usr/bin/pkill -x DoctKey >/dev/null 2>&1 || true",
            "/bin/sleep 1",
            "if [ -e \(qTarget) ]; then /bin/mv \(qTarget) \(qBackup); fi",
            "if ! /usr/bin/ditto \(qSource) \(qTarget); then /bin/rm -rf \(qTarget); if [ -e \(qBackup) ]; then /bin/mv \(qBackup) \(qTarget); fi; exit 1; fi",
            "/bin/rm -rf \(qBackup)",
            "/bin/rm -rf \(qWorkRoot)",
            "console_uid=$(/usr/bin/stat -f '%u' /dev/console)",
            "/bin/launchctl asuser \"$console_uid\" /bin/sh -c \(PrivilegedInstaller.shellQuote(userLaunch))"
        ]

        let needsAdministrator = target.hasPrefix("/Library/")
        if needsAdministrator {
            commands.insert("/usr/sbin/chown -R root:wheel \(qTarget) && /bin/chmod -R go+rX \(qTarget)", at: 4)
        }
        let result: (status: Int32, output: String)
        if needsAdministrator {
            let script = PrivilegedInstaller.administratorScript(forShellCommands: commands)
            result = runProcess("/usr/bin/osascript", ["-e", script])
        } else {
            result = runProcess("/bin/sh", ["-c", commands.joined(separator: " && ")])
        }
        if needsAdministrator, PrivilegedInstaller.isUserCancellation(exitCode: result.status, stderr: result.output) {
            throw UpdateError.cancelled
        }
        guard result.status == 0 else {
            throw UpdateError.processFailed("Không cài được bản cập nhật (mã lỗi \(result.status)).")
        }
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (127, error.localizedDescription)
        }
    }

    private static func normalizedVersion(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
    }

    private static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        func components(_ value: String) -> [Int]? {
            let core = normalizedVersion(value).split(separator: "-", maxSplits: 1).first.map(String.init) ?? value
            let parts = core.split(separator: ".")
            guard !parts.isEmpty else { return nil }
            let numbers = parts.compactMap { Int($0) }
            return numbers.count == parts.count ? numbers : nil
        }
        guard let left = components(lhs), let right = components(rhs) else { return false }
        for index in 0..<max(left.count, right.count) {
            let leftPart = index < left.count ? left[index] : 0
            let rightPart = index < right.count ? right[index] : 0
            if leftPart != rightPart { return leftPart > rightPart }
        }
        return false
    }

    private static func isTrustedReleaseURL(_ url: URL) -> Bool {
        url.scheme == "https"
            && url.host == "github.com"
            && url.path.hasPrefix("/\(repository)/releases/download/")
    }

    private enum UpdateError: LocalizedError {
        case invalidRelease
        case downloadFailed
        case invalidArchive
        case invalidBundle
        case signatureInvalid
        case signatureMismatch
        case cancelled
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidRelease: return "Bản phát hành không có gói DoctKey hợp lệ."
            case .downloadFailed: return "Không tải được gói cập nhật từ GitHub."
            case .invalidArchive: return "Gói cập nhật rỗng hoặc có kích thước không hợp lệ."
            case .invalidBundle: return "Gói tải về không phải DoctKey hoặc sai phiên bản."
            case .signatureInvalid: return "Chữ ký của bản cập nhật không hợp lệ."
            case .signatureMismatch: return "Bản cập nhật không cùng nhà phát triển ký với ứng dụng đang cài."
            case .cancelled: return "Bạn đã huỷ quyền cài đặt; phiên bản hiện tại vẫn được giữ nguyên."
            case .processFailed(let message): return message
            }
        }
    }
}
