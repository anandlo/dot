import Foundation

/// The kind of surface a transcript is being typed into.
///
/// The app is the only signal Dot has, and it is a good one: Slack wants the
/// words as they were said, a source file wants one line, and a commit subject
/// field wants neither a period nor a paragraph. The mapping is a table of
/// bundle identifiers, and any row can be corrected by hand.
public enum DictationTarget: String, Codable, Sendable, CaseIterable, Equatable {
    /// No rewrite at all, beyond collapsing the whitespace a person never
    /// typed on purpose.
    case plain
    /// A conversation: newlines stay, a lone trailing period goes.
    case chat
    /// A source file or a terminal: one line, no trailing sentence period.
    case code
    /// A git commit subject: one line, no trailing period, never truncated.
    case commit
    /// A document: paragraphs stay, the first letter is capitalised and the
    /// text ends in a full stop.
    case document

    /// The name the settings list and the card's chip show.
    public var title: String {
        switch self {
        case .plain: "Plain"
        case .chat: "Chat"
        case .code: "Code"
        case .commit: "Commit"
        case .document: "Document"
        }
    }

    /// One line about what the overlay does to the words.
    public var detail: String {
        switch self {
        case .plain: "Your words, with repeated spaces collapsed."
        case .chat: "Keeps newlines and drops a single trailing full stop."
        case .code: "One line, with a trailing full stop removed."
        case .commit: "One line, no trailing full stop, never shortened."
        case .document: "Keeps paragraphs, capitalises the opening and ends in a full stop."
        }
    }

    /// The bundle identifiers that select each target by name.
    ///
    /// Only apps whose dominant text field is the target are listed. A commit
    /// summary is the reason a person opens GitHub Desktop or Sourcetree, so
    /// those rows name ``commit``; every other app can be corrected with an
    /// override, which is why the table does not have to guess.
    static let table: [String: DictationTarget] = [
        // Chat.
        "com.tinyspeck.slackmacgap": .chat,
        "com.hnc.Discord": .chat,
        "com.apple.MobileSMS": .chat,
        "com.microsoft.teams": .chat,
        "com.microsoft.teams2": .chat,
        "net.whatsapp.WhatsApp": .chat,
        "org.telegram.desktop": .chat,

        // Code.
        "com.apple.dt.Xcode": .code,
        "com.microsoft.VSCode": .code,
        "com.microsoft.VSCodeInsiders": .code,
        "com.sublimetext.4": .code,
        "com.sublimetext.3": .code,
        "dev.zed.Zed": .code,
        "com.apple.Terminal": .code,
        "com.googlecode.iterm2": .code,
        "dev.warp.Warp-Stable": .code,
        "com.mitchellh.ghostty": .code,
        "io.alacritty": .code,
        "net.kovidgoyal.kitty": .code,
        "com.github.wez.wezterm": .code,

        // A commit subject field.
        "com.github.GitHubClient": .commit,
        "com.fournova.Tower3": .commit,
        "com.fournova.Tower": .commit,
        "com.syntevo.SmartGit": .commit,
        "com.torusknot.SourceTreeNotMAS": .commit,

        // A document.
        "com.apple.Notes": .document,
        "com.apple.iWork.Pages": .document,
        "com.apple.TextEdit": .document,
        "com.apple.mail": .document,
        "com.microsoft.Word": .document,
    ]

    /// The families whose bundle identifiers all select one target.
    ///
    /// JetBrains ships one application per language with a bundle identifier of
    /// its own, and every one of them is a code editor.
    static let prefixes: [(prefix: String, target: DictationTarget)] = [
        ("com.jetbrains.", .code),
    ]

    /// The target a bundle identifier names, before any override.
    ///
    /// - Parameter bundleIdentifier: the identifier of the frontmost app.
    /// - Returns: the table's answer, or `nil` when the app is not one Dot
    ///   knows.
    public static func table(for bundleIdentifier: String?) -> DictationTarget? {
        guard let id = normalized(bundleIdentifier) else { return nil }
        if let exact = table[id] { return exact }
        for entry in prefixes where id.hasPrefix(entry.prefix) {
            return entry.target
        }
        return nil
    }

    /// The target for a bundle identifier, with the user's overrides winning.
    ///
    /// An app Dot has never heard of is ``plain``: the rewrite is opt-in, and a
    /// target guessed for an unknown app could only damage the words.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: the identifier of the frontmost app, or `nil`.
    ///   - overrides: the per-app rows the person set in settings.
    public static func resolved(
        bundleIdentifier: String?,
        overrides: [String: DictationTarget] = [:]
    ) -> DictationTarget {
        guard let id = normalized(bundleIdentifier) else { return .plain }
        if let override = overrides[id] { return override }
        return table(for: id) ?? .plain
    }

    /// The overrides without rows that cannot name an app.
    ///
    /// - Parameter overrides: the stored rows.
    /// - Returns: the rows whose key is a bundle identifier.
    public static func normalizedOverrides(
        _ overrides: [String: DictationTarget]
    ) -> [String: DictationTarget] {
        var next: [String: DictationTarget] = [:]
        for (key, target) in overrides {
            guard let id = normalized(key) else { continue }
            next[id] = target
        }
        return next
    }

    /// A bundle identifier without surrounding whitespace, or `nil`.
    static func normalized(_ bundleIdentifier: String?) -> String? {
        let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
