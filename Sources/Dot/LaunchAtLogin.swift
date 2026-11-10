import Foundation
import ServiceManagement

/// Whether Dot starts with the Mac.
///
/// Supports both `SMAppService.mainApp` and the user LaunchAgent plist
/// (`~/Library/LaunchAgents/com.local.dot.plist`) installed by `scripts/install.sh`.
/// When running an ad-hoc signed build or a bundle outside `/Applications`,
/// `SMAppService.mainApp.register()` either throws or leaves the service in
/// `.requiresApproval`; falling back to the LaunchAgent plist ensures the
/// Launch at Login toggle in Settings and the menu bar always works reliably.
enum LaunchAtLogin {
    /// The LaunchAgent label used by `scripts/install.sh`.
    static let agentLabel = "com.local.dot"

    /// Default path to `~/Library/LaunchAgents/com.local.dot.plist`.
    static var defaultAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    /// Whether Dot is registered to start at login.
    static var isEnabled: Bool {
        if SMAppService.mainApp.status == .enabled {
            return true
        }
        return isAgentEnabled(at: defaultAgentURL)
    }

    /// Turns the login item on or off.
    static func set(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try? SMAppService.mainApp.register()
            }
            if SMAppService.mainApp.status == .enabled {
                return
            }
            try writeAgent(at: defaultAgentURL, executablePath: resolvedExecutablePath())
        } else {
            if SMAppService.mainApp.status == .enabled {
                try? SMAppService.mainApp.unregister()
            }
            try removeAgent(at: defaultAgentURL)
        }
    }

    // MARK: - LaunchAgent management

    /// Checks whether a LaunchAgent plist exists at `url` with `RunAtLoad` enabled.
    static func isAgentEnabled(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any]
        else {
            return false
        }
        return (plist["RunAtLoad"] as? Bool) ?? false
    }

    /// Writes the LaunchAgent plist so `launchd` starts Dot at login.
    static func writeAgent(at url: URL, executablePath: String) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let logDir = "\(home)/Library/Logs/Dot"
        try? FileManager.default.createDirectory(
            atPath: logDir,
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProcessType": "Background",
            "ProgramArguments": [executablePath],
            "EnvironmentVariables": ["HOME": home],
            "RunAtLoad": true,
            "StandardOutPath": "\(logDir)/launchd.out.log",
            "StandardErrorPath": "\(logDir)/launchd.err.log",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    /// Removes the LaunchAgent plist if present.
    static func removeAgent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func resolvedExecutablePath() -> String {
        let installed = "/Applications/Dot.app/Contents/MacOS/Dot"
        if FileManager.default.isExecutableFile(atPath: installed) {
            return installed
        }
        return Bundle.main.executableURL?.path ?? installed
    }
}
