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
                page: Self.validatedReleasePage(release.page)
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

    /// Validates that a release page URL points to an HTTPS GitHub release under Dot's repository.
    static func validatedReleasePage(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              !url.pathComponents.contains(".."),
              !url.path.split(separator: "/").contains("..")
        else { return nil }
        let expectedPrefix = (ProductLinks.github.path + "/releases/").lowercased()
        guard url.path.lowercased().hasPrefix(expectedPrefix) else { return nil }
        return url
    }

    /// Compares two SemVer 2.0.0 strings, respecting prerelease precedence and ignoring build metadata.
    static func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        guard let parsed1 = SemVer(v1), let parsed2 = SemVer(v2) else {
            return false
        }
        return parsed1 > parsed2
    }

    private struct SemVer: Comparable {
        enum PrereleaseIdentifier: Comparable {
            case numeric(String)
            case alphanumeric(String)

            init?(_ raw: String) {
                guard !raw.isEmpty else { return nil }
                if raw.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    self = .numeric(raw)
                } else {
                    self = .alphanumeric(raw)
                }
            }

            static func == (lhs: PrereleaseIdentifier, rhs: PrereleaseIdentifier) -> Bool {
                switch (lhs, rhs) {
                case (.numeric(let a), .numeric(let b)):
                    return compareNumericStrings(a, b) == .orderedSame
                case (.alphanumeric(let a), .alphanumeric(let b)):
                    return a == b
                case (.numeric, .alphanumeric), (.alphanumeric, .numeric):
                    return false
                }
            }

            static func < (lhs: PrereleaseIdentifier, rhs: PrereleaseIdentifier) -> Bool {
                switch (lhs, rhs) {
                case (.numeric(let a), .numeric(let b)):
                    return compareNumericStrings(a, b) == .orderedAscending
                case (.numeric, .alphanumeric):
                    return true
                case (.alphanumeric, .numeric):
                    return false
                case (.alphanumeric(let a), .alphanumeric(let b)):
                    return a < b
                }
            }

            private static func compareNumericStrings(_ a: String, _ b: String) -> ComparisonResult {
                let trimA = String(a.drop(while: { $0 == "0" }))
                let trimB = String(b.drop(while: { $0 == "0" }))
                if trimA.count != trimB.count {
                    return trimA.count < trimB.count ? .orderedAscending : .orderedDescending
                }
                if trimA == trimB { return .orderedSame }
                return trimA < trimB ? .orderedAscending : .orderedDescending
            }
        }

        let major: Int
        let minor: Int
        let patch: Int
        let prerelease: [PrereleaseIdentifier]

        init?(_ raw: String) {
            var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
                trimmed.removeFirst()
            }
            if let buildIndex = trimmed.firstIndex(of: "+") {
                trimmed = String(trimmed[..<buildIndex])
            }
            guard !trimmed.isEmpty else { return nil }

            let corePart: String
            let prePart: String?
            if let dash = trimmed.firstIndex(of: "-") {
                corePart = String(trimmed[..<dash])
                prePart = String(trimmed[trimmed.index(after: dash)...])
            } else {
                corePart = trimmed
                prePart = nil
            }

            let coreStrings = corePart.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...3).contains(coreStrings.count) else { return nil }
            var nums: [Int] = []
            for part in coreStrings {
                guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let value = Int(part)
                else { return nil }
                nums.append(value)
            }
            self.major = nums[0]
            self.minor = nums.count > 1 ? nums[1] : 0
            self.patch = nums.count > 2 ? nums[2] : 0

            if let prePart {
                guard !prePart.isEmpty else { return nil }
                let parts = prePart.split(separator: ".", omittingEmptySubsequences: false)
                var identifiers: [PrereleaseIdentifier] = []
                for part in parts {
                    guard let id = PrereleaseIdentifier(String(part)) else { return nil }
                    identifiers.append(id)
                }
                self.prerelease = identifiers
            } else {
                self.prerelease = []
            }
        }

        static func < (lhs: SemVer, rhs: SemVer) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
            if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return false }
            if lhs.prerelease.isEmpty { return false }
            if rhs.prerelease.isEmpty { return true }
            for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
                if left != right { return left < right }
            }
            return lhs.prerelease.count < rhs.prerelease.count
        }
    }

    /// Names both versions as people read them, unless the readable forms
    /// coincide (`1.0.0-rc.1` and `1.0.0-rc1` both read "1.0.0 RC 1"), where
    /// only the exact versions tell the two builds apart.
    static func updateAvailableText(latest: String, current: String) -> String {
        var latestName = ProductVersion.displayName(latest)
        var currentName = ProductVersion.displayName(current)
        if latestName == currentName {
            latestName = latest
            currentName = current
        }
        return "Dot \(latestName) is available. This is \(currentName)."
    }

    private func showUpdateAvailableAlert(latestVersion: String, releaseURL: URL?) {
        let alert = NSAlert()
        alert.messageText = "Update available"
        alert.informativeText = Self.updateAvailableText(latest: latestVersion, current: Self.currentVersion)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download update")
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
        alert.messageText = "You are up to date"
        alert.informativeText = "Dot \(ProductVersion.displayName(currentVersion)) is currently the newest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showCheckFailedAlert() {
        let alert = NSAlert()
        alert.messageText = "Update check failed"
        alert.informativeText = "Could not reach the update server at \(Self.downloadPageURL.host ?? "the website")."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Visit website")
        alert.addButton(withTitle: "OK")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.downloadPageURL)
        }
    }
}
