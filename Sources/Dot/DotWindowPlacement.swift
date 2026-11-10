import CoreGraphics

/// Where a light window goes.
///
/// The light windows keep one fixed content size and are centred in the usable
/// part of a screen. The geometry is pure so the centring and the off-screen
/// policy can be tested without a display attached.
enum DotWindowPlacement {
    /// How much of a window must still be on a screen for its position to be
    /// kept: enough to grab it and drag it back.
    static let minimumVisibleExtent: CGFloat = 48

    /// The content rect of a `contentSize` window centred on a screen.
    ///
    /// The rect is centred in `visibleFrame`, the part of the screen below the
    /// menu bar and above the Dock, and is kept inside it. The requested size
    /// is never changed: the views are fixed size, so a window that does not
    /// fit is pinned to the bottom-left of the visible frame instead of being
    /// cropped.
    ///
    /// - Parameters:
    ///   - contentSize: the fixed content size of the window.
    ///   - visibleFrame: the usable frame of the screen, in screen coordinates.
    /// - Returns: a content rect whose origin keeps the window on screen.
    static func contentFrame(
        contentSize: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        let width = contentSize.width.isFinite ? max(0, contentSize.width) : 0
        let height = contentSize.height.isFinite ? max(0, contentSize.height) : 0
        let size = CGSize(width: width, height: height)
        let visible = visibleFrame.standardized

        guard visible.width > 0,
              visible.height > 0,
              visible.minX.isFinite,
              visible.minY.isFinite,
              visible.width.isFinite,
              visible.height.isFinite
        else {
            return CGRect(origin: .zero, size: size)
        }

        return CGRect(
            x: clamp(visible.midX - width / 2, length: width, minimum: visible.minX, maximum: visible.maxX),
            y: clamp(visible.midY - height / 2, length: height, minimum: visible.minY, maximum: visible.maxY),
            width: width,
            height: height
        )
    }

    /// Whether enough of a window is on one of the screens.
    ///
    /// A window the user has moved to the edge of a display still counts as
    /// on screen as long as a `minimumVisibleExtent` square of it remains.
    /// Only a frame that no screen can still show is off screen.
    ///
    /// - Parameters:
    ///   - frame: the frame of the window, in screen coordinates.
    ///   - visibleFrames: the usable frames of the screens, in screen
    ///     coordinates.
    ///   - minimumVisible: the smallest visible width and height that keeps
    ///     the window reachable.
    /// - Returns: `true` when the window should keep its position.
    static func isOnScreen(
        _ frame: CGRect,
        visibleFrames: [CGRect],
        minimumVisible: CGFloat = DotWindowPlacement.minimumVisibleExtent
    ) -> Bool {
        let frame = frame.standardized
        guard frame.width > 0,
              frame.height > 0,
              frame.minX.isFinite,
              frame.minY.isFinite,
              frame.width.isFinite,
              frame.height.isFinite
        else {
            return false
        }

        let extent = minimumVisible.isFinite
            ? max(0, minimumVisible)
            : Self.minimumVisibleExtent

        return visibleFrames.contains { visibleFrame in
            let visible = visibleFrame.standardized
            guard visible.width > 0,
                  visible.height > 0,
                  visible.minX.isFinite,
                  visible.minY.isFinite,
                  visible.width.isFinite,
                  visible.height.isFinite
            else {
                return false
            }

            let overlap = frame.intersection(visible)
            guard !overlap.isNull, !overlap.isEmpty else { return false }
            return overlap.width >= min(extent, frame.width)
                && overlap.height >= min(extent, frame.height)
        }
    }

    private static func clamp(
        _ origin: CGFloat,
        length: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        guard maximum - minimum > length else { return minimum }
        return min(max(origin, minimum), maximum - length)
    }
}
