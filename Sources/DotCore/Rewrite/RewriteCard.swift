import Foundation

/// The rewrite layer of the transcript card.
///
/// It is a value, and the HUD draws it: the card has one shape and one set of
/// measurements whether it shows a bare transcript or the chips, and a separate
/// window for a rewrite would be a second surface to find.
public struct RewriteCard: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Chips idle under the original words.
        case offered
        /// A style is running; the rewrite streams into the body.
        case rewriting(styleID: String, title: String)
        /// The rewrite replaced the text, and was faithful.
        case applied(styleID: String)
        /// The rewrite was applied through the clipboard.
        case copied(styleID: String)
        /// The check found an error; nothing has been written yet.
        case blocked(styleID: String, error: String)
        /// The attempt did not finish.
        case failed
    }

    /// The sentence the card shows when the rewrite went to the clipboard.
    public static let clipboardNote = "Couldn't replace the text in this app. The rewrite is on the clipboard."
    /// The sentence the card shows when the attempt did not finish.
    public static let failureNote = "The rewrite didn't finish."

    /// The words the take was made of. Chips always rewrite these, so a second
    /// style rewrites the original rather than the first rewrite.
    public var original: String
    /// The styles the card offers, built-ins first.
    public var choices: [RewriteStyle]
    /// Where the layer is.
    public var phase: Phase
    /// The rewrite as it has arrived.
    public var rewrite: String
    /// The first warning of the check, shown as the badge's tooltip.
    public var warning: String?
    /// One line under the body: why the rewrite went to the clipboard, or that
    /// the attempt failed.
    public var note: String?
    /// The application the transcript was pasted into.
    public var destination: String?
    /// Whether Undo is offered, which is only after a rewrite was written.
    public var canUndo: Bool

    public init(
        original: String,
        choices: [RewriteStyle],
        phase: Phase = .offered,
        rewrite: String = "",
        warning: String? = nil,
        note: String? = nil,
        destination: String? = nil,
        canUndo: Bool = false
    ) {
        self.original = original
        self.choices = choices
        self.phase = phase
        self.rewrite = rewrite
        self.warning = warning
        self.note = note
        self.destination = destination
        self.canUndo = canUndo
    }

    /// The id of the style the layer is running or showing.
    public var activeStyleID: String? {
        switch phase {
        case .offered, .failed: nil
        case .rewriting(let id, _): id
        case .applied(let id), .copied(let id), .blocked(let id, _): id
        }
    }

    /// Whether the chip row is drawn. The confirmation of a blocked rewrite is
    /// two capsules, not chips: the choice is yes or no, not another style.
    public var showsChips: Bool {
        if case .blocked = phase { return false }
        return !choices.isEmpty
    }

    /// Whether the body is the rewrite rather than the transcript.
    public var showsRewrite: Bool {
        switch phase {
        case .rewriting, .applied, .copied, .blocked: true
        case .offered, .failed: false
        }
    }

    /// Whether the rewrite is still arriving.
    public var isStreaming: Bool {
        if case .rewriting = phase { return true }
        return false
    }

    /// Whether the body of the original is faded to two lines under the
    /// streaming rewrite.
    public var dimsOriginal: Bool { isStreaming }
}
