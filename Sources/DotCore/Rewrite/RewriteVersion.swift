import Foundation

/// One reviewable version of a transcript.
///
/// The original is version 0 and is never replaced. Every successful request
/// appends one more version, in the order the person asked for them, including
/// a second request for a style they already ran. A version is immutable: its
/// id, its words and its place in the list do not change when another one is
/// generated or selected.
public struct RewriteVersion: Identifiable, Equatable, Sendable {
    /// Where the words came from.
    public enum Origin: Equatable, Sendable {
        /// The transcript as it was dictated.
        case original
        /// One requested rewrite, named by the style that was asked for.
        case style(String)
    }

    /// The version's stable id. Version 0 is always the original.
    public let id: Int
    /// Where the words came from.
    public let origin: Origin
    /// The name the chip and VoiceOver use, e.g. `Original` or `Concise`.
    public let title: String
    /// The words this version shows, already assembled for delivery.
    public let text: String
    /// Which request of this style this is, starting at 1. The original is 0.
    public let ordinal: Int
    /// The first warning of the check, when it found something to review.
    public let warning: String?

    /// Creates a version.
    public init(
        id: Int,
        origin: Origin,
        title: String,
        text: String,
        ordinal: Int = 0,
        warning: String? = nil
    ) {
        self.id = id
        self.origin = origin
        self.title = title
        self.text = text
        self.ordinal = ordinal
        self.warning = warning
    }

    /// The original transcript.
    public static func original(id: Int = 0, text: String) -> RewriteVersion {
        RewriteVersion(id: id, origin: .original, title: "Original", text: text)
    }

    /// Whether these are the dictated words rather than a model's rewrite.
    public var isOriginal: Bool { origin == .original }

    /// The style that produced this version, or `nil` for the original.
    public var styleID: String? {
        guard case .style(let id) = origin else { return nil }
        return id
    }

    /// The label with the repeat number, e.g. `Concise 2`, or just the title.
    public var label: String {
        ordinal > 1 ? "\(title) \(ordinal)" : title
    }

    /// What VoiceOver reads for this version.
    public var accessibilityLabel: String {
        isOriginal ? "Original transcript" : "\(label) rewrite"
    }
}

// MARK: - Persistence

extension RewriteVersion: Codable {
    /// The keys one version takes in the history file.
    ///
    /// The origin is stored as the style's id rather than as an encoded enum,
    /// so a style this build no longer offers still reads back with its own id
    /// and title: the words a person already paid for are not a style's to take
    /// away. Nothing about a delivery - destination, phase, draft - is written,
    /// because none of it is a version.
    private enum CodingKeys: String, CodingKey {
        case id
        case style
        case title
        case text
        case ordinal
        case warning
    }

    /// Reads one version, keeping every field it can.
    ///
    /// A malformed field is defaulted rather than thrown: an `id` written as a
    /// string, an `ordinal` that is missing, or a warning of the wrong type must
    /// not cost the person the words. The one field that cannot be defaulted is
    /// `text`, because a version with no words has nothing to review.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .text,
                in: container,
                debugDescription: "a version with no text is not a version"
            )
        }
        let styleID = (try? container.decodeIfPresent(String.self, forKey: .style)) ?? nil
        let storedTitle = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil
        // A record with no title is named after its style, never after a
        // sentence: a title is a label, and a prompt is not reconstructed here.
        let fallbackTitle = styleID ?? "Original"
        self.init(
            id: (try? container.decode(Int.self, forKey: .id)) ?? 0,
            origin: styleID.map { .style($0) } ?? .original,
            title: storedTitle?.isEmpty == false ? storedTitle ?? fallbackTitle : fallbackTitle,
            text: text,
            ordinal: max(0, (try? container.decode(Int.self, forKey: .ordinal)) ?? 0),
            warning: (try? container.decodeIfPresent(String.self, forKey: .warning)) ?? nil
        )
    }

    /// Writes one version, omitting what is not there.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if let styleID {
            try container.encode(styleID, forKey: .style)
        }
        try container.encode(title, forKey: .title)
        try container.encode(text, forKey: .text)
        try container.encode(ordinal, forKey: .ordinal)
        try container.encodeIfPresent(warning, forKey: .warning)
    }
}

/// The completed versions a history entry keeps, and the one it was showing.
///
/// It is the only part of a card that survives a launch: the original is the
/// entry's own text, and a draft, a refusal, a delivery destination or an
/// insertion anchor are states of one take rather than versions of a
/// transcript. The snapshot therefore holds what can be reviewed offline and
/// nothing that could be mistaken for a delivery.
///
/// Version 0 is never stored. It is rebuilt from the entry's text every time,
/// so a file cannot disagree with the transcript about what was dictated.
public struct RewriteSnapshot: Codable, Equatable, Sendable {
    /// The largest id a stored version may have.
    ///
    /// Ids are allocated by incrementing, so a file that claims a version id of
    /// `Int.max` would make the next id overflow. The cap is far above any real
    /// list - a transcript with a hundred rewrites would be unusable long
    /// before it - and it is what makes the increment safe to compute.
    public static let maximumVersionID = 1_000_000

    /// The completed rewrites, in the order they were asked for.
    public var versions: [RewriteVersion]
    /// The id the card was showing; 0 is the original.
    public var selectedVersionID: Int

    /// Creates a snapshot from values that are already normalised.
    public init(versions: [RewriteVersion], selectedVersionID: Int = 0) {
        self.versions = versions
        self.selectedVersionID = selectedVersionID
    }

    /// The completed versions of a card, when it has any worth keeping.
    ///
    /// A card that is still streaming, or one whose draft the check refused, has
    /// no completed version to store: its body is a draft, not a version. That
    /// is also why persisting a card is silent per token - the snapshot of a
    /// streaming card is `nil` until a version is appended.
    public init?(card: RewriteCard) {
        guard !card.isStreaming, !card.isBlocked else { return nil }
        let completed = card.versions.filter { !$0.isOriginal }
        guard !completed.isEmpty else { return nil }
        guard let normalized = RewriteSnapshot(
            versions: completed,
            selectedVersionID: card.selectedVersionID
        ).normalized() else { return nil }
        self = normalized
    }

    /// The id the next generated version takes.
    ///
    /// The addition is checked because the value can come from a file: a
    /// snapshot that was built by hand rather than read through
    /// ``normalized()`` must not be able to trap the app.
    public var nextVersionID: Int {
        guard let maximum = versions.map(\.id).max() else { return 1 }
        let (next, overflow) = maximum.addingReportingOverflow(1)
        guard !overflow else { return Self.maximumVersionID + 1 }
        return min(next, Self.maximumVersionID + 1)
    }

    /// The snapshot with the invariants the rest of the app relies on.
    ///
    /// The rules are the ones a file cannot be trusted to follow: only
    /// completed rewrites, only unique positive ids, and a selection that names
    /// one of them or the original. A record whose id is malformed keeps its
    /// words and is given the next free id instead of being dropped, because a
    /// version that is readable is worth more than the number it arrived with.
    ///
    /// - Returns: the normalised snapshot, or `nil` when no version is left.
    public func normalized() -> RewriteSnapshot? {
        var kept: [(version: RewriteVersion, id: Int?)] = []
        var used: Set<Int> = []
        for version in versions {
            guard !version.isOriginal,
                  !version.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            let valid = (1 ... Self.maximumVersionID).contains(version.id)
                && !used.contains(version.id)
            if valid { used.insert(version.id) }
            kept.append((version, valid ? version.id : nil))
        }
        guard !kept.isEmpty else { return nil }
        var next = (used.max() ?? 0) + 1
        var resolved: [RewriteVersion] = []
        for entry in kept {
            let id: Int
            if let stored = entry.id {
                id = stored
            } else {
                guard next <= Self.maximumVersionID else { continue }
                id = next
                next += 1
            }
            resolved.append(RewriteVersion(
                id: id,
                origin: entry.version.origin,
                title: entry.version.title,
                text: entry.version.text,
                ordinal: entry.version.ordinal,
                warning: entry.version.warning
            ))
        }
        guard !resolved.isEmpty else { return nil }
        let selection = resolved.contains { $0.id == selectedVersionID } ? selectedVersionID : 0
        return RewriteSnapshot(versions: resolved, selectedVersionID: selection)
    }

    /// Reads a snapshot, dropping the records that cannot be read.
    ///
    /// One bad record must not cost the person the other versions, so each one
    /// is decoded on its own and a failure is skipped. A snapshot with nothing
    /// readable left throws, which the history reads as "this entry has no
    /// versions" while keeping the transcript.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let records = (try? container.decode([LossyVersion].self, forKey: .versions)) ?? []
        let selection = (try? container.decode(Int.self, forKey: .selectedVersionID)) ?? 0
        guard let normalized = RewriteSnapshot(
            versions: records.compactMap(\.version),
            selectedVersionID: selection
        ).normalized() else {
            throw DecodingError.dataCorruptedError(
                forKey: .versions,
                in: container,
                debugDescription: "no readable version"
            )
        }
        self = normalized
    }

    private enum CodingKeys: String, CodingKey {
        case versions
        case selectedVersionID
    }

    /// One version that may fail to decode without failing the list.
    private struct LossyVersion: Decodable {
        let version: RewriteVersion?

        init(from decoder: Decoder) throws {
            version = try? RewriteVersion(from: decoder)
        }
    }
}

/// What the card shows when a transcript comes back from the history.
///
/// A click on a remembered transcript copies the words that were dictated; the
/// card that follows is a review surface. If the entry kept versions, they are
/// shown even when the rewrite is switched off, has no key, or the transcript
/// is now too long, because saved words do not need a service. If it kept none,
/// the ordinary style choices appear when this build could run one right now -
/// being ready is not the same as asking, and nothing is generated until a chip
/// is clicked.
public enum RewriteRestorePlan: Equatable, Sendable {
    /// The card shows the versions the entry saved.
    case saved(RewriteSnapshot)
    /// The card offers the styles a fresh take would offer.
    case choices
    /// The card shows the transcript alone.
    case none

    /// The card for one remembered transcript.
    ///
    /// - Parameters:
    ///   - saved: the versions the entry keeps, when it has any.
    ///   - eligible: whether a request could run for this transcript now.
    public static func of(saved: RewriteSnapshot?, eligible: Bool) -> RewriteRestorePlan {
        if let saved, let normalized = saved.normalized(), !normalized.versions.isEmpty {
            return .saved(normalized)
        }
        return eligible ? .choices : .none
    }
}
