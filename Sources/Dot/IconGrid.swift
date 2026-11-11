import SwiftUI

/// The macOS app icon grid: an 824 point body on a 1024 point canvas.
///
/// Every number here was measured on the icon Apple ships, not assumed. The 256
/// point representation inside the system apps' `AppIcon.icns` (Notes,
/// Calculator and Freeform agree pixel for pixel) puts a 206 pixel body at
/// inset 25 with the body centred, which is 824 and 100 at 1024: the body is
/// 0.8047 of the canvas. The same representation shows the shadow reaching 11
/// pixels below the body, 9 to the sides and 7 above.
///
/// The margin is rounded to a whole pixel so the body's edge lands on a pixel
/// boundary at every size the iconset draws. At 256, 512 and 1024 that rounding
/// is exact; below 256 it costs at most half a pixel of body.
enum DotIconGrid {
    /// The canvas Apple draws on.
    static let reference: CGFloat = 1024
    /// The body's side on that canvas.
    static let referenceBody: CGFloat = 824
    /// The corner radius as a fraction of the body: 185.4 of 824.
    ///
    /// Drawn with `RoundedRectangle(cornerRadius:style: .continuous)`, which is
    /// the system's own corner. Against the measured icon its silhouette
    /// differs by at most one pixel at 256 and its area by 0.2 percent, where
    /// the superellipse this replaced was 1.5 percent too full and up to four
    /// pixels out at a shallow depth.
    static let cornerRatio: CGFloat = 0.225

    /// The body as a fraction of the canvas.
    static var bodyRatio: CGFloat { referenceBody / reference }

    /// One margin as a fraction of the canvas.
    static var marginRatio: CGFloat { (reference - referenceBody) / 2 / reference }

    /// One margin as a fraction of the body.
    ///
    /// A view whose frame is the body rather than the canvas pads by this.
    static var paddingRatio: CGFloat { marginRatio / bodyRatio }

    /// The margin on each side of a canvas of `canvas` pixels, at least one.
    ///
    /// One pixel is the floor because a tile with no transparent margin is the
    /// defect this grid exists to fix: it would draw a hard square.
    static func margin(inCanvas canvas: CGFloat) -> CGFloat {
        max(1, (canvas * marginRatio).rounded())
    }

    /// The body's side in a canvas of `canvas` pixels.
    static func body(inCanvas canvas: CGFloat) -> CGFloat {
        canvas - 2 * margin(inCanvas: canvas)
    }
}

/// One mark drawn as a macOS icon: the grid, the system corner, the shadow.
///
/// `content` is drawn at the body's edge and must fill its frame. The corner
/// and the drop shadow are applied here so no caller can bake a second, wrong
/// one, and the shadow is drawn into the margin rather than past it.
///
/// `size` is the canvas: a bare 1024 draws the shipped 824 body with 100 points
/// of transparent margin, which is what macOS 14 and 15 read as a rounded icon.
struct DotIconMaster<Content: View>: View {
    /// The canvas edge in points, rendered at scale 1 so it is also pixels.
    let size: CGFloat
    /// Whether the icon casts its shadow into the margin.
    var showsShadow = true
    /// The artwork at the body's edge.
    let content: () -> Content

    var body: some View {
        let body = DotIconGrid.body(inCanvas: size)
        content()
            .frame(width: body, height: body)
            .clipShape(DotSquircle())
            .overlay(
                DotSquircle()
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(DotRim.top), location: 0.0),
                                .init(color: .white.opacity(DotRim.foot), location: 1.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: max(0.5, body * DotRim.width)
                    )
            )
            .shadow(
                color: .black.opacity(showsShadow ? DotShadow.alpha : 0),
                radius: body * DotShadow.radius,
                x: 0,
                y: body * DotShadow.offset
            )
            .frame(width: size, height: size)
    }
}
