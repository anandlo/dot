import CoreGraphics
import Foundation

/// The measurements of the rewrite layer of the transcript card.
///
/// The layer sits under the transcript body: the chips when the card is idle,
/// a note line when the rewrite went to the clipboard, and the two capsules
/// when a check refused it. They are declared here so the card's size and the
/// view that draws it cannot disagree about the height of a row.
public enum HUDRewriteLayout {
    /// The height of a chip, in points.
    public static let chipHeight: CGFloat = 24
    /// The padding inside a chip, on the left and the right, in points.
    public static let chipHPadding: CGFloat = 10
    /// The gap between two chips, in points.
    public static let chipGap: CGFloat = 6
    /// The size of a chip's label, in points.
    public static let chipFontSize: CGFloat = 11.5
    /// The size of the dot in the faithfulness badge, in points.
    public static let badgeDotSize: CGFloat = 6
    /// The height of the faithfulness badge, in points.
    public static let badgeHeight: CGFloat = 18
    /// The gap between the header label and the badge, in points.
    public static let badgeGap: CGFloat = 8
    /// The distance between the body and the first row under it, in points.
    public static let rowTopGap: CGFloat = 12
    /// The gap between a note line and the row under it, in points.
    public static let rowGap: CGFloat = 8
    /// The height of a note line, in points.
    public static let noteHeight: CGFloat = 15
    /// The distance between the body and a note line, in points.
    public static let noteGap: CGFloat = 6
    /// The size of the note and the error line, in points.
    public static let noteFontSize: CGFloat = 11.5
    /// The height of the Undo capsule and of the two confirmation capsules.
    public static let actionHeight: CGFloat = 24
    /// The gap between the two confirmation capsules, in points.
    public static let actionGap: CGFloat = 8
    /// The padding of a confirmation capsule, on the left and the right.
    public static let actionHPadding: CGFloat = 14
    /// The most lines the dimmed original is drawn on while a rewrite streams.
    public static let dimmedOriginalLines = 2
    /// The size of the dimmed original, in points.
    public static let dimmedFontSize: CGFloat = 13
    /// The height of one line of the dimmed original, in points.
    public static let dimmedLineHeight: CGFloat = 18
    /// The gap between the dimmed original and the streaming rewrite.
    public static let dimmedGap: CGFloat = 6

    /// The height the layer adds below the transcript body.
    ///
    /// - Parameters:
    ///   - showsChips: whether the chip row is drawn.
    ///   - showsActions: whether the two confirmation capsules are drawn.
    ///   - noteLines: how many note lines sit under the body.
    /// - Returns: the height of everything under the body, or zero.
    public static func extraHeight(
        showsChips: Bool,
        showsActions: Bool,
        noteLines: Int
    ) -> CGFloat {
        var height: CGFloat = 0
        if noteLines > 0 {
            height += noteGap + CGFloat(noteLines) * noteHeight
        }
        if showsActions || showsChips {
            height += (noteLines > 0 ? rowGap : rowTopGap)
            height += showsActions ? actionHeight : chipHeight
        }
        guard height > 0 else { return 0 }
        return height + HUDState.verticalPadding
    }
}
