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
    ///
    /// The chip row is one line, and ``extraHeight(showsChips:showsActions:noteLines:)``
    /// budgets it once. Styles that outgrow the card scroll sideways rather
    /// than wrapping, so a new built-in or a long custom label costs width, not
    /// height.
    public static let chipHeight: CGFloat = 24
    /// The width of the fade that says the chip row continues, in points.
    ///
    /// It is also the trailing room the row keeps, so the last chip can scroll
    /// clear of the fade instead of ending under it.
    public static let chipOverflowWidth: CGFloat = 26
    /// The width of the slot the overflow chevron is drawn in, in points.
    ///
    /// The chevron is not a layer over the chips: the style viewport is clipped
    /// where this slot begins, so the slot comes out of the styles' width and
    /// the chevron is drawn on the card's own surface, never on a label. The
    /// slot is sized for the mark and the clearance it promises rather than for
    /// a control: a ten point mark centred in it keeps eleven points on each
    /// side, and it stays narrower than the version arrows it sits between.
    public static let chipOverflowSlotWidth: CGFloat = 20
    /// The padding inside a chip, on the left and the right, in points.
    public static let chipHPadding: CGFloat = 10
    /// The gap between two chips, in points.
    public static let chipGap: CGFloat = 6
    /// The width of one previous/next arrow, in points.
    ///
    /// The arrows live in the same 24 point row as the chips, so navigation
    /// costs width rather than a second row of the card. It is also the width of
    /// the rerun control: all three are 24 by 24 point targets, because the card
    /// is clicked at rather than typed into.
    public static let versionArrowWidth: CGFloat = 24
    /// The size of a chip's label, in points.
    ///
    /// Eleven and a half, the size the row was drawn at before the typeface
    /// changed. It was dropped to ten and a quarter only to fit a wider face,
    /// and the face at 11.5 draws the five shipped styles' chips and the gaps
    /// between them at 382.0 points (408.0 with the row's trailing room)
    /// against the card's 528. The type needs no longer give way, so the point
    /// and a quarter stayed.
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
    /// The height of a confirmation capsule. The legacy Undo control used the
    /// same shape; no current cursor paste sets `canUndo`.
    public static let actionHeight: CGFloat = 24
    /// The gap between the two confirmation capsules, in points.
    public static let actionGap: CGFloat = 8
    /// The padding of a confirmation capsule, on the left and the right.
    public static let actionHPadding: CGFloat = 14
    /// The least height the streaming draft keeps for itself, in points.
    public static let streamingDraftMinHeight: CGFloat = 44
    /// The tallest the card may be, in points.
    ///
    /// The header, the body and every row under it share one budget: a card
    /// that grew past this would cover the application the person is reading
    /// in. The body gives up the room the rows under it need.
    public static let maximumCardHeight: CGFloat = 312

    /// The height the body needs while a rewrite streams.
    ///
    /// The body is the draft, and the draft is measured from the words that were
    /// there before the request, never from the tokens arriving: a body that grew
    /// with every delta would move the card under the reader's eyes and make the
    /// row below it twitch once per token.
    ///
    /// The arithmetic is deliberately the same on both sides of the click. Before
    /// it, the body is the selected version's text in a card that already pays
    /// for the chip row; at the click the body is that same text, because the
    /// draft is still empty and the card draws the selection until the first
    /// token lands. So the card is exactly as tall at the click frame as it was
    /// the frame before: the number below is the number ``transcriptContentHeight``
    /// gave for the same words, held at the shortest body the card draws and at
    /// nothing else. The status block that used to be added on top is gone, and
    /// with it the seventy points the card used to grow by on the click.
    ///
    /// ``streamingDraftMinHeight`` is the fallback for an original whose height
    /// cannot be measured at all: the shortest text the card can hold already
    /// needs more than it, so it never widens a card that was measured.
    ///
    /// - Parameter originalContentHeight: the height the selected version's text
    ///   needs, with the padding around it.
    /// - Returns: the height of the streaming body.
    public static func streamingContentHeight(originalContentHeight: CGFloat) -> CGFloat {
        guard !originalContentHeight.isNaN else { return streamingDraftMinHeight }
        return max(originalContentHeight, HUDTranscript.minBodyHeight)
    }

    /// The tallest body the card can pay for, once the layer under it is drawn.
    ///
    /// - Parameter extraHeight: the height the rewrite layer adds under the body.
    /// - Returns: the room left inside ``maximumCardHeight``, never below the
    ///   shortest body the card draws.
    public static func maximumBodyHeight(extraHeight: CGFloat) -> CGFloat {
        let available = maximumCardHeight - HUDState.headerHeight - 1 - extraHeight
        return max(HUDTranscript.minBodyHeight, available)
    }

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
