import Foundation
import ServiceManagement

/// Whether Dot starts with the Mac.
///
/// Two mechanisms are used together. `SMAppService.mainApp` is the supported
/// one; an ad-hoc signed build, or a bundle outside `/Applications`, either
/// throws on `register()` or leaves the service in `.requiresApproval`, so the
/// user LaunchAgent plist that `scripts/install.sh` also writes is the fallback.
/// Whichever of the two is in place, the Settings toggle and the menu reflect it.
enum LaunchAtLogin {
    /// The LaunchAgent label, which is the app's bundle identifier.
    ///
    /// `scripts/build.sh` writes the identifier from `scripts/config.sh` into
    /// the bundle, and `scripts/install.sh` names the agent after the same
    /// value, so the app and its agent can never carry two identities. The
    /// fallback is for a binary with no bundle — `swift run` — where there is no
    /// identifier to read.
    static var agentLabel: String {
        Bundle.main.bundleIdentifier ?? "com.anandlo.dot"
    }

    /// The labels this app wrote its agent under before the identity was
    /// unified.
    ///
    /// Their plists are removed whenever the current one is written or removed:
    /// an upgrade must not leave a second agent starting the same app.
    static let legacyAgentLabels = ["com.local.dot"]

    /// Default path to the LaunchAgent plist this build uses.
    static var defaultAgentURL: URL {
        agentURL(for: agentLabel)
    }

    /// The plist path of a given agent label.
    private static func agentURL(for label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
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
        defer { removeLegacyAgents() }
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

    /// Removes the agents written under an earlier label.
    ///
    /// A stale plist both lies about the state of the toggle and starts the app
    /// a second time at login, so it goes with every change to the current one.
    static func removeLegacyAgents() {
        for label in legacyAgentLabels where label != agentLabel {
            try? removeAgent(at: agentURL(for: label))
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
