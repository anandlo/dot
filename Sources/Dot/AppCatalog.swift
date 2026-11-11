import AppKit
import UniformTypeIdentifiers

/// A bundle identifier and the application it belongs to, if it is installed.
///
/// The formatting list stores identifiers because that is what the frontmost
/// application reports. A person reads names, so every row asks the system for
/// the name and the icon once and falls back to the identifier when the app is
/// not on this Mac.
struct AppCatalogEntry: Equatable {
    /// The identifier stored in the configuration.
    let bundleID: String
    /// The name the Finder shows, without the extension, or `nil`.
    let name: String?
    /// The application's own icon, or the generic application icon.
    let icon: NSImage

    /// Whether the application is installed where the system can find it.
    var isInstalled: Bool { name != nil }

    /// What the row prints as its title.
    var title: String { name ?? bundleID }
}

/// The installed applications the formatting list can name.
@MainActor
enum AppCatalog {
    /// The system's description of one bundle identifier.
    ///
    /// - Parameter bundleID: the identifier as the configuration stores it.
    /// - Returns: the entry, with the generic application icon when no
    ///   application on this Mac claims the identifier.
    static func entry(for bundleID: String) -> AppCatalogEntry {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return AppCatalogEntry(
                bundleID: bundleID,
                name: nil,
                icon: genericApplicationIcon
            )
        }
        return AppCatalogEntry(
            bundleID: bundleID,
            name: displayName(of: url),
            icon: NSWorkspace.shared.icon(forFile: url.path)
        )
    }

    /// The icon of an application bundle that is not installed here.
    ///
    /// `UTType.application` resolves to the generic *document* icon on this
    /// system, which is the wrong picture next to a bundle identifier. The
    /// application-bundle type is the one that draws the generic app.
    private static var genericApplicationIcon: NSImage {
        NSWorkspace.shared.icon(for: .applicationBundle)
    }

    /// The name of the application at a URL, as the Finder writes it.
    static func displayName(of url: URL) -> String? {
        let name = FileManager.default.displayName(atPath: url.path)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasSuffix(".app") ? String(trimmed.dropLast(4)) : trimmed
    }

    /// Asks for an application and returns its identifier.
    ///
    /// The panel opens on `/Applications`, which is where the apps a person
    /// dictates into live. A bundle with no identifier cannot be named by the
    /// frontmost-application signal, so it is not offered.
    static func chooseBundleID() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.title = "Add an app"
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}
