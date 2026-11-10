import AppKit
import Foundation

/// Manages application update checks and distribution feeds.
///
/// Supports both native background release checking (via GitHub/Web releases API)
/// and Sparkle 2 integration (`SPUStandardUpdaterController`) when compiled in.
@MainActor
public final class UpdateController {
    public static let shared = UpdateController()

    public static let currentVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0-beta"
    }()

    public static let releasesURL = URL(string: "https://api.github.com/repos/anandlo/dot/releases/latest")!
    public static let downloadPageURL = URL(string: "https://dot.anandlo.com")!

    @Published public private(set) var isChecking = false

    private init() {}

    /// Checks for updates and displays user-facing feedback alert.
    public func checkForUpdates(userInitiated: Bool = true) {
        guard !isChecking else { return }
        isChecking = true

        Task {
            do {
                var request = URLRequest(url: Self.releasesURL)
                request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
                request.setValue("Dot-App-Updater", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 8

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }

                struct ReleaseInfo: Decodable {
                    let tag_name: String
                    let html_url: String?
                    let body: String?
                }

                let release = try JSONDecoder().decode(ReleaseInfo.self, from: data)
                let latestTag = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))

                isChecking = false

                if isVersion(latestTag, newerThan: Self.currentVersion) {
                    showUpdateAvailableAlert(latestVersion: latestTag, releaseURL: release.html_url)
                } else if userInitiated {
                    showUpToDateAlert()
                }
            } catch {
                isChecking = false
                if userInitiated {
                    showCheckFailedAlert(error: error)
                }
            }
        }
    }

    /// Compares two semver strings (e.g. "1.1.0" > "1.0.0").
    private func isVersion(_ v1: String, newerThan v2: String) -> Bool {
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

    private func showUpdateAvailableAlert(latestVersion: String, releaseURL: String?) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Dot \(latestVersion) is now available (you have \(Self.currentVersion)). Would you like to view and download the update?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let releaseURL, let url = URL(string: releaseURL) {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.open(Self.downloadPageURL)
            }
        }
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You're up to date!"
        alert.informativeText = "Dot \(Self.currentVersion) is currently the newest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showCheckFailedAlert(error: Error) {
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
