import Foundation

/// The rewrite layer of the transcript card.
///
/// It is a value, and the HUD draws it: the card has one shape and one set of
/// measurements whether it shows a bare transcript or the chips, and a separate
/// window for a rewrite would be a second surface to find.
///
/// The layer holds every version the take has produced, with the original at
/// index 0. Selecting a version changes only what the card shows and what Copy
/// and Paste would deliver; it never writes anywhere on its own. Each version is
/// built from ``original``, never from the version before it.
public struct RewriteCard: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Chips idle under the words.
        case offered
        /// A style is running; the draft streams into the body.
        case rewriting(styleID: String, title: String)
        /// An explicit Paste wrote the named version where the transcript was.
        case applied(versionID: Int)
        /// An explicit Copy put the named version on the clipboard.
        case copied(versionID: Int)
        /// The check found an error; the draft is not a version until it is kept.
        case blocked(styleID: String, error: String)
        /// The attempt did not finish.
        case failed
    }

    /// Which way the selection moved, for the brief directional transition.
    public enum Navigation: Equatable, Sendable {
        case previous
        case next
    }

    /// The sentence the card shows when a Paste had to fall back to the clipboard.
    public static let clipboardNote = "Couldn't replace the text in this app. The version is on the clipboard."
    /// The sentence the card shows when an explicit paste at the cursor could
    /// not be verified and the version went to the clipboard instead.
    public static let pasteFailedNote = "Couldn't paste at the cursor. The version is on the clipboard."
    /// The sentence the card shows when the write may have happened but could
    /// not be read back. It does not claim the field is unchanged.
    public static let pasteUnverifiedNote =
        "The paste could not be verified. The version is on the clipboard; check the field before typing."
    /// The sentence the card shows when the attempt did not finish.
    public static let failureNote = "The rewrite didn't finish."
    /// The sentence the card shows when the service cut the answer off.
    public static let truncationNote = "The rewrite was cut off, so nothing was added."
    /// The sentence the card shows when an inline edit cleared older versions.
    public static let rebaseNote = "The transcript changed, so the earlier versions were cleared."
    /// The sentence the card shows when the original is not the text that was
    /// inserted, so replacing it would not be a truthful restore.
    public static let originalDiffersNote =
        "The original is not the text that was inserted. It is on the clipboard."

    /// The words the take was made of. Every generation uses these, and every
    /// version is a function of them.
    public var original: String
    /// The styles the card offers, built-ins first.
    public var choices: [RewriteStyle]
    /// Where the layer is.
    public var phase: Phase
    /// The original followed by every successful generation, in request order.
    public var versions: [RewriteVersion]
    /// The id of the version the body and Copy/Paste act on.
    public var selectedVersionID: Int
    /// The rewrite as it arrives, or the draft a refused check is holding.
    public var draft: String
    /// When each append of the draft landed, oldest first.
    ///
    /// The body dims the words that have just arrived and brings them up to the
    /// card's ink over ``RewriteDraftRamp/duration``. The stream is the only
    /// thing that knows when that was, so it records it as it appends; an empty
    /// table means the draft is not arriving and nothing ramps.
    public var draftChunks: [RewriteDraftChunk]
    /// The first warning of the check for the draft.
    public var draftWarning: String?
    /// One line under the body: why a Paste fell back, or that the attempt failed.
    public var note: String?
    /// The application the transcript was delivered into.
    public var destination: String?
    /// The application an explicit paste actually wrote into, when it differs
    /// from the take's destination.
    public var deliveryDestination: String?
    /// Whether the legacy anchored Undo is offered. A cursor paste clears it:
    /// the text and selection that preceded the write are unknown, so offering
    /// Undo would promise a restore that cannot be performed.
    public var canUndo: Bool
    /// Which way the last selection moved, when there was one.
    public var lastNavigation: Navigation?

    public init(
        original: String,
        choices: [RewriteStyle],
        phase: Phase = .offered,
        versions: [RewriteVersion]? = nil,
        selectedVersionID: Int = 0,
        draft: String = "",
        draftChunks: [RewriteDraftChunk] = [],
        draftWarning: String? = nil,
        note: String? = nil,
        destination: String? = nil,
        deliveryDestination: String? = nil,
        canUndo: Bool = false,
        lastNavigation: Navigation? = nil
    ) {
        let resolved = versions ?? [RewriteVersion.original(text: original)]
        self.original = original
        self.choices = choices
        self.phase = phase
        self.versions = resolved.isEmpty
            ? [RewriteVersion.original(text: original)]
            : resolved
        self.selectedVersionID = self.versions.contains { $0.id == selectedVersionID }
            ? selectedVersionID
            : (self.versions.first?.id ?? 0)
        self.draft = draft
        self.draftChunks = draftChunks
        self.draftWarning = draftWarning
        self.note = note
        self.destination = destination
        self.deliveryDestination = deliveryDestination
        self.canUndo = canUndo
        self.lastNavigation = lastNavigation
    }

    // MARK: - The selection

    /// The version the card is showing.
    public var selectedVersion: RewriteVersion {
        versions.first { $0.id == selectedVersionID }
            ?? versions.first
            ?? RewriteVersion.original(text: original)
    }

    /// Where the selected version sits in the list.
    public var selectedIndex: Int {
        versions.firstIndex { $0.id == selectedVersionID } ?? 0
    }

    /// Whether a previous version can be reached.
    public var canGoPrevious: Bool { selectedIndex > 0 }

    /// Whether a later version can be reached.
    public var canGoNext: Bool { selectedIndex < versions.count - 1 }

    /// The body's words: the draft while it arrives, otherwise the selection.
    public var bodyText: String {
        if isStreaming || isBlocked {
            return draft
        }
        return selectedVersion.text
    }

    /// The words the body draws, which are the selection until the draft exists.
    ///
    /// A click on a style does not blank the surface: the body keeps the version
    /// the cream pill says the person is reading until the first token lands, and
    /// then it switches to the draft. Drawing an empty body for the first second
    /// of every request took the words away at the moment they were asked about.
    public var visibleBodyText: String {
        if isStreaming, draft.isEmpty { return selectedVersion.text }
        return bodyText
    }

    /// Appends what the service sent, and records when it landed.
    ///
    /// The chunk table is pruned as it grows: an append that is older than the
    /// ramp is drawn in the body's ink whatever this table says, so keeping it
    /// would only make every frame walk a longer list than it can use.
    ///
    /// - Parameters:
    ///   - text: the whole draft as it stands after the append.
    ///   - time: the card's clock when the append happened.
    public mutating func appendDraft(_ text: String, at time: Double) {
        draft = text
        draftChunks.append(RewriteDraftChunk(count: text.count, time: time))
        guard time.isFinite else {
            draftChunks = []
            return
        }
        draftChunks.removeAll { time - $0.time >= RewriteDraftRamp.duration }
    }

    /// Drops the draft and the arrivals that dated it.
    public mutating func clearDraft() {
        draft = ""
        draftChunks = []
    }

    /// The first warning of the check for whatever the body shows.
    public var warning: String? {
        if isStreaming || isBlocked {
            return draftWarning
        }
        return selectedVersion.warning
    }

    /// Whether a Copy or a Paste may deliver the selection right now.
    public var canDeliverSelected: Bool {
        !isStreaming && !isBlocked
    }

    /// The latest version a style produced, if it produced one.
    public func latestVersion(styleID: String) -> RewriteVersion? {
        versions.last { $0.styleID == styleID }
    }

    /// How many versions a style produced.
    public func versionCount(styleID: String) -> Int {
        versions.filter { $0.styleID == styleID }.count
    }

    // MARK: - Navigation

    /// Selects one version by id, clearing a delivery note from a previous one.
    ///
    /// - Returns: whether the selection moved.
    @discardableResult
    public mutating func select(versionID: Int) -> Bool {
        guard let index = versions.firstIndex(where: { $0.id == versionID }) else {
            return false
        }
        let previous = selectedIndex
        selectedVersionID = versionID
        guard index != previous else { return true }
        lastNavigation = index > previous ? .next : .previous
        dropDeliveryState()
        return true
    }

    /// Selects the version before the current one, stopping at the original.
    ///
    /// - Returns: whether the selection moved.
    @discardableResult
    public mutating func goPrevious() -> Bool {
        guard canGoPrevious else { return false }
        selectedVersionID = versions[selectedIndex - 1].id
        lastNavigation = .previous
        dropDeliveryState()
        return true
    }

    /// Selects the version after the current one, stopping at the last.
    ///
    /// - Returns: whether the selection moved.
    @discardableResult
    public mutating func goNext() -> Bool {
        guard canGoNext else { return false }
        selectedVersionID = versions[selectedIndex + 1].id
        lastNavigation = .next
        dropDeliveryState()
        return true
    }

    /// Selects the original and discards a draft that was not kept.
    public mutating func keepOriginal() {
        selectedVersionID = versions.first?.id ?? 0
        lastNavigation = .previous
        phase = .offered
        clearDraft()
        draftWarning = nil
        note = nil
        dropDeliveryState()
    }

    /// Appends a successful generation and selects it.
    ///
    /// The id is supplied by the caller so an asynchronous request can be tied
    /// to the version it was allowed to create.
    ///
    /// - Returns: the version that was appended.
    @discardableResult
    public mutating func append(
        id: Int,
        style: RewriteStyle,
        text: String,
        warning: String?
    ) -> RewriteVersion {
        let ordinal = versionCount(styleID: style.id) + 1
        let version = RewriteVersion(
            id: id,
            origin: .style(style.id),
            title: style.title,
            text: text,
            ordinal: ordinal,
            warning: warning
        )
        versions.append(version)
        selectedVersionID = version.id
        lastNavigation = .next
        phase = .offered
        clearDraft()
        draftWarning = nil
        note = nil
        dropDeliveryState()
        return version
    }

    /// Replaces the original after an inline edit and clears versions built on
    /// the old words. The caller decides whether there were any to clear.
    ///
    /// - Returns: whether older generated versions were discarded.
    @discardableResult
    public mutating func rebase(original text: String) -> Bool {
        let hadVersions = versions.contains { !$0.isOriginal } || isStreaming || isBlocked
        original = text
        versions = [RewriteVersion.original(text: text)]
        selectedVersionID = versions[0].id
        phase = .offered
        clearDraft()
        draftWarning = nil
        note = hadVersions ? Self.rebaseNote : nil
        deliveryDestination = nil
        canUndo = false
        lastNavigation = nil
        return hadVersions
    }

    /// Clears a delivery outcome when the selection moves away from it.
    private mutating func dropDeliveryState() {
        switch phase {
        case .applied, .copied:
            phase = .offered
            deliveryDestination = nil
        case .offered, .rewriting, .blocked, .failed:
            break
        }
    }

    // MARK: - What the layer shows

    /// The id of the style the layer is running.
    public var activeStyleID: String? {
        if case .rewriting(let id, _) = phase { return id }
        return nil
    }

    /// The title of the style the layer is running, when one is.
    ///
    /// The status line above the streaming body names the style from the moment
    /// the request is made, before the first token exists: the phase carries the
    /// title the chip row already knows, so nothing has to wait for the network
    /// to say what is being asked for.
    public var activeStyleTitle: String? {
        if case .rewriting(_, let title) = phase { return title }
        return nil
    }

    /// Whether the chip row is drawn. The confirmation of a blocked rewrite is
    /// two capsules, not chips: the choice is yes or no, not another style.
    public var showsChips: Bool {
        if case .blocked = phase { return false }
        return !choices.isEmpty || versions.count > 1
    }

    /// Whether the body is a rewrite rather than the transcript.
    public var showsRewrite: Bool {
        if isStreaming || isBlocked { return true }
        return !selectedVersion.isOriginal
    }

    /// Whether the rewrite is still arriving.
    public var isStreaming: Bool {
        if case .rewriting = phase { return true }
        return false
    }

    /// Whether the check refused the draft and is waiting for a decision.
    public var isBlocked: Bool {
        if case .blocked = phase { return true }
        return false
    }
}
