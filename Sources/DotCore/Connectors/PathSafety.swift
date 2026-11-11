import Foundation

/// Decides which paths a file tool may touch.
///
/// The Files tools are the only ones that can destroy something a person cannot
/// get back from an undo stack, and the model chooses the path. Every path is
/// therefore canonicalised first (standardised, then symlinks resolved, so a
/// link inside the home folder cannot point the tool at `/System`) and then
/// checked against three rules:
///
/// 1. A system location is never writable, whatever the model asked for.
/// 2. Another account's home folder is never readable or writable.
/// 3. A write, a move or a trash happens inside the person's home folder only.
///
/// Reads are wider than writes on purpose: finding a file in an external volume
/// is useful, moving one there is not part of the product.
public struct PathSafety: Sendable, Equatable {
    /// What the tool is about to do with the path.
    public enum Intent: Sendable, Equatable, CaseIterable {
        /// Read or search.
        case read
        /// Create or overwrite a file inside the home folder.
        case write
        /// Move the item to the Trash.
        case trash
        /// The item being moved or renamed.
        case moveSource
        /// Where a moved item lands.
        case moveDestination

        /// Whether the intent changes what is on disk.
        var isMutation: Bool {
            switch self {
            case .read: false
            case .write, .trash, .moveSource, .moveDestination: true
            }
        }
    }

    /// Why a path was refused.
    public enum Failure: Error, Equatable, Sendable {
        /// The path was empty, or only whitespace.
        case empty
        /// The path was not absolute.
        case notAbsolute
        /// The path held a character a path cannot hold.
        case malformed
        /// The path is, or is inside, a system location.
        case systemLocation(String)
        /// The path belongs to another account.
        case anotherUser(String)
        /// A write, move or trash outside the home folder.
        case outsideHome(String)
        /// The path is the home folder itself.
        case isHome
        /// The path is Dot itself, or inside its bundle.
        case protected(String)
        /// An application bundle, which a voice command may not move or trash.
        case applicationBundle(String)

        /// The sentence the model reads.
        public var message: String {
            switch self {
            case .empty:
                "The path is empty."
            case .notAbsolute:
                "The path must start with / or ~."
            case .malformed:
                "The path contains a character a path cannot contain."
            case .systemLocation(let path):
                "Dot will not touch a system location: \(path)."
            case .anotherUser(let path):
                "Dot will not touch another person's folder: \(path)."
            case .outsideHome(let path):
                "Dot only changes files inside your home folder: \(path)."
            case .isHome:
                "Dot will not change your home folder itself."
            case .protected(let path):
                "Dot will not touch its own application: \(path)."
            case .applicationBundle(let path):
                "Dot will not move or trash an application: \(path)."
            }
        }
    }

    /// The account's home folder.
    public let home: URL
    /// Paths no tool may touch, whatever the intent. Dot's own bundle is one.
    public let protected: [URL]
    /// The account this process runs as, for the other-user rule.
    ///
    /// It is read from the real home folder rather than from ``home`` so a test
    /// that uses a temporary home still knows which `/Users` entry is its own.
    private let accountName: String?

    /// Locations that belong to the system rather than to a person.
    private static let systemRoots = [
        "/System", "/Library", "/usr", "/bin", "/sbin", "/private",
        "/etc", "/var", "/dev", "/cores", "/Applications", "/opt",
    ]

    /// Creates a guard.
    ///
    /// - Parameters:
    ///   - home: the folder writes are confined to. The real home folder by
    ///     default; a test supplies its own.
    ///   - protected: paths that are never touched. Dot's own bundle by default.
    public init(home: URL? = nil, protected: [URL]? = nil) {
        let realHome = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        self.home = (home ?? realHome).standardizedFileURL.resolvingSymlinksInPath()
        self.protected = (protected ?? [Bundle.main.bundleURL])
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        let components = realHome.standardizedFileURL.pathComponents
        self.accountName = components.count >= 3 && components[1] == "Users" ? components[2] : nil
    }

    /// Canonicalises and checks a path.
    ///
    /// - Parameters:
    ///   - path: a path from the model. `~` is expanded; anything else must be
    ///     absolute.
    ///   - intent: what the tool is about to do.
    /// - Returns: the canonical URL the tool should use, not the string it was
    ///   given.
    /// - Throws: ``Failure`` when the path is outside what the intent allows.
    public func check(_ path: String, intent: Intent) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.empty }
        guard !trimmed.contains("\0") else { throw Failure.malformed }
        let expanded = expand(trimmed)
        guard expanded.hasPrefix("/") else { throw Failure.notAbsolute }
        let canonical = canonical(expanded)

        // Dot's own bundle is refused whatever it contains and wherever it is.
        for url in protected {
            if canonical.path == url.path || canonical.path.hasPrefix(url.path + "/") {
                throw Failure.protected(canonical.path)
            }
        }
        // The home folder is the one place a tool may write, so it is checked
        // before the system list: a home that happens to live under /var is
        // still the person's own folder.
        if isInsideHome(canonical) {
            if intent.isMutation {
                try checkMutation(canonical, intent: intent)
            }
            return canonical
        }
        for root in Self.systemRoots {
            if canonical.path == root || canonical.path.hasPrefix(root + "/") {
                throw Failure.systemLocation(canonical.path)
            }
        }
        try checkAnotherUser(canonical)
        if intent.isMutation {
            try checkMutation(canonical, intent: intent)
        }
        return canonical
    }

    /// Self.targets `~` and rejects the `~other` form.
    private func expand(_ path: String) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.path + path.dropFirst(1) }
        return path
    }

    /// Standardises a path and resolves every symlink in it.
    ///
    /// `resolvingSymlinksInPath` stops at the first component that does not
    /// exist, which is exactly the case a move or a rename hits: the
    /// destination file is not there yet, and the folder above it may be a
    /// link. The deepest existing ancestor is resolved first and the missing
    /// tail is appended to it, so `~/link/new.txt` with `link` pointing at
    /// `/System` resolves to `/System/new.txt` rather than staying in the home
    /// folder.
    private func canonical(_ path: String) -> URL {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var missing: [String] = []
        while url.path != "/", !FileManager.default.fileExists(atPath: url.path) {
            missing.insert(url.lastPathComponent, at: 0)
            url = url.deletingLastPathComponent()
        }
        var resolved = url.resolvingSymlinksInPath()
        for component in missing {
            resolved.appendPathComponent(component)
        }
        return resolved
    }

    /// Whether a canonical path is the home folder or inside it.
    private func isInsideHome(_ url: URL) -> Bool {
        url.path == home.path || url.path.hasPrefix(home.path + "/")
    }

    /// Refuses a home folder that belongs to somebody else.
    private func checkAnotherUser(_ url: URL) throws {
        let components = url.pathComponents
        guard components.count >= 3, components[1] == "Users" else { return }
        guard let accountName else { return }
        if components[2] != accountName {
            throw Failure.anotherUser(url.path)
        }
    }

    /// Applies the rules that only exist for an operation that changes disk.
    private func checkMutation(_ url: URL, intent: Intent) throws {
        let path = url.path
        let insideHome = path == home.path || path.hasPrefix(home.path + "/")
        guard insideHome else { throw Failure.outsideHome(path) }
        guard path != home.path else { throw Failure.isHome }
        if intent == .trash || intent == .moveSource || intent == .moveDestination {
            if url.pathExtension.lowercased() == "app" {
                throw Failure.applicationBundle(path)
            }
        }
    }
}
