import AppKit
import DotCore
import Foundation

/// Checks GitHub Releases for a newer build.
///
/// There is no updater framework in the app: the check reads the project's
/// GitHub releases, compares the newest tag with the version the bundle
/// declares, and — when the tag is newer — offers a link to the release page.
/// Nothing is downloaded or installed by Dot itself.
///
/// GitHub's `/releases/latest` leaves prereleases out, and every Dot release is
/// one while the product is in beta, so that endpoint answers 404. The check
/// therefore falls back to `/releases?per_page=1` — newest first, prereleases
/// included — exactly as `scripts/install-remote.sh` does.
@MainActor
public final class UpdateController {
    public static let shared = UpdateController()

    /// The version this build reports, read from the bundle.
    public static let currentVersion = ProductVersion.current

    /// The Releases endpoint the check reads first.
    public static let releasesURL = ProductLinks.latestRelease
    /// The list endpoint the check reads when the first cannot answer.
    public static let releasesListURL = ProductLinks.releaseList
    /// Where a person is sent when there is no release page to open.
    public static let downloadPageURL = ProductLinks.website

    @Published public private(set) var isChecking = false

    /// What one check found.
    public enum CheckResult: Equatable, Sendable {
        /// The running build is the newest release.
        case upToDate(current: String)
        /// A newer release exists, with its page when the response named one.
        case newer(version: String, page: URL?)
        /// No endpoint could name a release.
        case failed
    }

    private init() {}

    /// Asks GitHub for the newest release and compares it with this build.
    ///
    /// This is the network half of ``checkForUpdates(userInitiated:)`` without
    /// the alert: the About window shows the same answer inline, in the same
    /// words, from the same request.
    ///
    /// - Returns: what the newest release means for this build.
    public func check() async -> CheckResult {
        let feed = ReleaseFeed(latest: Self.releasesURL, list: Self.releasesListURL)
        do {
            let release = try await feed.newest()
            guard Self.isVersion(release.version, newerThan: Self.currentVersion) else {
                return .upToDate(current: Self.currentVersion)
            }
            return .newer(
                version: release.version,
                page: release.page.flatMap { URL(string: $0) }
            )
        } catch {
            Log.shared.warn("update.check.failed", [
                "error": .string(error.localizedDescription),
            ])
            return .failed
        }
    }

    /// Checks for updates and displays user-facing feedback alert.
    public func checkForUpdates(userInitiated: Bool = true) {
        guard !isChecking else { return }
        isChecking = true

        Task {
            let result = await check()
            isChecking = false

            switch result {
            case .newer(let version, let page):
                showUpdateAvailableAlert(latestVersion: version, releaseURL: page)
            case .upToDate(let current):
                if userInitiated {
                    showUpToDateAlert(currentVersion: current)
                }
            case .failed:
                if userInitiated {
                    showCheckFailedAlert()
                }
            }
        }
    }

    /// Compares two semver strings (e.g. "1.1.0" > "1.0.0").
    static func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(parts1.count, parts2.count) {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 > p2 { return true }
            if p1 < p2 { return false }
        }
        return false
    }

    private func showUpdateAvailableAlert(latestVersion: String, releaseURL: URL?) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Dot \(latestVersion) is now available (you have \(Self.currentVersion)). Would you like to view and download the update?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let releaseURL {
                NSWorkspace.shared.open(releaseURL)
            } else {
                NSWorkspace.shared.open(Self.downloadPageURL)
            }
        }
    }

    private func showUpToDateAlert(currentVersion: String) {
        let alert = NSAlert()
        alert.messageText = "You're up to date!"
        alert.informativeText = "Dot \(currentVersion) is currently the newest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showCheckFailedAlert() {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = "Could not reach the update server. Please verify your connection or check \(Self.downloadPageURL.host ?? "our website")."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Visit Website")
        alert.addButton(withTitle: "OK")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.downloadPageURL)
        }
    }
}
