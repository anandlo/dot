import CoreGraphics

/// Where the HUD panel goes.
///
/// The panel is a fixed-size, transparent window. Only its frame is placed
/// here; the card animates inside it. The math is pure so the screen policy
/// and the clamping can be tested without a display attached.
enum HUDPlacement {
    /// The frame of the panel on a screen.
    ///
    /// The panel is centred horizontally, and its top edge sits `topInset`
    /// points below the top of the visible frame. The result is always clamped
    /// inside the visible frame, so a panel can never end up under the menu
    /// bar, past a screen edge, or behind the Dock. When the panel is larger
    /// than the visible frame, it is shrunk to fit.
    ///
    /// - Parameters:
    ///   - visibleFrame: the usable frame of the screen, in screen coordinates.
    ///   - panelSize: the fixed size of the panel.
    ///   - topInset: the distance from the top of the visible frame to the
    ///     top edge of the panel.
    /// - Returns: a frame inside `visibleFrame`.
    static func frame(
        visibleFrame: CGRect,
        panelSize: CGSize,
        topInset: CGFloat
    ) -> CGRect {
        let visible = visibleFrame.standardized
        let finiteInset = topInset.isFinite ? max(0, topInset) : 0

        guard visible.width > 0,
              visible.height > 0,
              visible.origin.x.isFinite,
              visible.origin.y.isFinite,
              visible.width.isFinite,
              visible.height.isFinite,
              panelSize.width.isFinite,
              panelSize.height.isFinite,
              panelSize.width > 0,
              panelSize.height > 0
        else {
            let width = panelSize.width.isFinite ? max(0, panelSize.width) : 0
            let height = panelSize.height.isFinite ? max(0, panelSize.height) : 0
            return CGRect(x: 0, y: 0, width: width, height: height)
        }

        let width = min(panelSize.width, visible.width)
        let height = min(panelSize.height, visible.height)

        let x = min(
            max(visible.midX - width / 2, visible.minX),
            visible.maxX - width
        )
        let y = min(
            max(visible.maxY - finiteInset - height, visible.minY),
            visible.maxY - height
        )

        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The origin of the panel on a screen.
    ///
    /// - Parameters:
    ///   - visibleFrame: the usable frame of the screen.
    ///   - panelSize: the fixed size of the panel.
    ///   - topInset: the distance from the top of the visible frame to the
    ///     top edge of the panel.
    /// - Returns: the origin of a frame inside `visibleFrame`.
    static func origin(
        visibleFrame: CGRect,
        panelSize: CGSize,
        topInset: CGFloat
    ) -> CGPoint {
        frame(
            visibleFrame: visibleFrame,
            panelSize: panelSize,
            topInset: topInset
        ).origin
    }

    /// The frame of the card inside the panel.
    ///
    /// The panel is larger than the card: the room around it is what the
    /// shadow is drawn into. The card is centred horizontally and hangs from
    /// the top of the panel, `topInset` below it, which is the same place the
    /// SwiftUI tree puts it. The result is what the pointer is tested against:
    /// a pointer in the shadow margin is not over the card.
    ///
    /// - Parameters:
    ///   - panelFrame: the frame of the panel, in screen coordinates.
    ///   - cardSize: the size of the card, in points.
    ///   - topInset: the distance from the top of the panel to the top of the
    ///     card, in points.
    /// - Returns: the card's frame, in the same coordinates as `panelFrame`.
    static func cardFrame(
        panelFrame: CGRect,
        cardSize: CGSize,
        topInset: CGFloat
    ) -> CGRect {
        let inset = topInset.isFinite ? max(0, topInset) : 0
        let width = cardSize.width.isFinite ? max(0, cardSize.width) : 0
        let height = cardSize.height.isFinite ? max(0, cardSize.height) : 0
        return CGRect(
            x: panelFrame.midX - width / 2,
            y: panelFrame.maxY - inset - height,
            width: width,
            height: height
        )
    }

    /// The index of the screen under a point.
    ///
    /// The point is `NSEvent.mouseLocation`, which is in the same global
    /// screen coordinates as `NSScreen.frame`. A point that is on no screen
    /// (for example after a display was unplugged) falls back to `fallback`,
    /// and then to the first screen.
    ///
    /// - Parameters:
    ///   - point: a point in screen coordinates.
    ///   - frames: the frames of the screens, in `NSScreen.screens` order.
    ///   - fallback: the index to use when no frame contains the point.
    /// - Returns: a valid index, or `nil` when there are no screens.
    static func screenIndex(
        containing point: CGPoint,
        frames: [CGRect],
        fallback: Int?
    ) -> Int? {
        guard !frames.isEmpty else { return nil }
        if let index = frames.firstIndex(where: { $0.standardized.contains(point) }) {
            return index
        }
        if let fallback, frames.indices.contains(fallback) {
            return fallback
        }
        return frames.indices.first
    }
}
