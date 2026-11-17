import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import Dot

/// A picture of a window as the window server composited it, and the
/// measurements the glass tests take from one.
///
/// `cacheDisplay` draws the view hierarchy the app built. A material is not in
/// that hierarchy: the window server composites it behind the window's content,
/// so the only picture that contains it is a capture of the window itself.
/// Everything here arranges those captures off every display, in a transparent
/// borderless window, and orders it out before returning.
enum WindowCapture {
    // MARK: - A picture

    /// One picture of a window: eight bits per channel, four channels, sRGB,
    /// rows from the top of the window down, and the pixels per point the
    /// window server captured it at.
    struct Pixels {
        let width: Int
        let height: Int
        var data: [UInt8]
        /// The pixels per point of the display the window server captured on.
        ///
        /// The capture is asked for at the best resolution the display offers
        /// and cannot ask for another one, so this is the display's own ratio:
        /// two on a Retina display, one on a display that is not. Every rect a
        /// test converts from points is scaled by it.
        var scale: CGFloat = 1

        /// One pixel as red, green and blue, 0 to 255.
        func pixel(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let index = (y * width + x) * 4
            return (Double(data[index]), Double(data[index + 1]), Double(data[index + 2]))
        }

        /// One pixel as red, green, blue and alpha, 0 to 255.
        func rgba(_ x: Int, _ y: Int) -> (Double, Double, Double, Double) {
            let index = (y * width + x) * 4
            return (
                Double(data[index]),
                Double(data[index + 1]),
                Double(data[index + 2]),
                Double(data[index + 3])
            )
        }

        /// One pixel as unpremultiplied red, green and blue, 0 to 255.
        ///
        /// The capture is drawn into a premultiplied buffer, so a pixel that is
        /// not opaque is divided by its own alpha before its colour means
        /// anything. An empty pixel has no colour and reads as zero.
        func unpremultiplied(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let value = rgba(x, y)
            guard value.3 > 0 else { return (0, 0, 0) }
            let alpha = value.3 / 255
            return (
                min(255, value.0 / alpha),
                min(255, value.1 / alpha),
                min(255, value.2 / alpha)
            )
        }

        /// Whether the whole picture is one colour, which is what a capture of a
        /// window the server never composited comes back as.
        ///
        /// A process without the screen recording right is handed a black or an
        /// empty picture rather than an error, so this is how the tests tell a
        /// material they cannot see from a material that drew nothing.
        var isBlank: Bool {
            guard width > 0, height > 0 else { return true }
            let first = pixel(0, 0)
            for y in stride(from: 0, to: height, by: 3) {
                for x in stride(from: 0, to: width, by: 3) {
                    let colour = pixel(x, y)
                    if abs(colour.0 - first.0) > 1
                        || abs(colour.1 - first.1) > 1
                        || abs(colour.2 - first.2) > 1
                    {
                        return false
                    }
                }
            }
            return true
        }
    }

    /// A rectangle of the picture, in pixels from its top left.
    struct Rect {
        var x: Int
        var y: Int
        var width: Int
        var height: Int

        /// The rectangle a view rect covers in a capture at a backing scale.
        static func points(_ rect: CGRect, scale: CGFloat) -> Rect {
            points(rect, scaleX: scale, scaleY: scale)
        }

        /// The rectangle a view rect covers in a capture, at two scales.
        ///
        /// The window server captures at the display's own pixel ratio, which a
        /// display in a scaled mode does not make an integer multiple of the
        /// window's points, so the horizontal and the vertical scale are read
        /// from the picture rather than assumed.
        static func points(_ rect: CGRect, scaleX: CGFloat, scaleY: CGFloat) -> Rect {
            Rect(
                x: Int((rect.minX * scaleX).rounded()),
                y: Int((rect.minY * scaleY).rounded()),
                width: Int((rect.width * scaleX).rounded()),
                height: Int((rect.height * scaleY).rounded())
            )
        }

        var midX: Int { x + width / 2 }
        var midY: Int { y + height / 2 }
    }

    // MARK: - Hosting

    /// Hosts a view in a transparent borderless window off every display.
    ///
    /// The window is at ``OffscreenWindow/origin``, has no shadow and no frame,
    /// and is transparent so a material has something to sample. It is ordered
    /// front so the window server composites it, and the run loop is run so the
    /// composite has happened before a capture is asked for.
    ///
    /// - Parameters:
    ///   - view: what the window shows.
    ///   - size: the window's content size, in points.
    /// - Returns: the window, to be handed to ``hide(_:)``.
    @MainActor
    static func show<V: View>(_ view: V, size: CGSize) -> NSWindow {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = OffscreenWindow(size: size, styleMask: [.borderless])
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.contentView = host
        window.orderFrontRegardless()
        spin(0.4)
        host.layoutSubtreeIfNeeded()
        CATransaction.flush()
        spin(0.2)
        return window
    }

    /// Orders a window from ``show(_:size:)`` out and drops its content.
    @MainActor
    static func hide(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
    }

    // MARK: - Capturing

    /// The picture of the window the window server composited.
    ///
    /// `CGWindowListCreateImage` is the only call that returns the composited
    /// window; it is reached through `dlsym` because the SDK marks it obsolete
    /// while the window server still answers it. The window's number is read on
    /// the main actor, where AppKit keeps it.
    @MainActor
    static func capture(_ window: NSWindow) -> Pixels? {
        spin(0.3)
        guard let image = windowImage(CGWindowID(window.windowNumber)) else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return Pixels(
            width: width,
            height: height,
            data: buffer,
            scale: window.frame.width > 0 ? CGFloat(width) / window.frame.width : 1
        )
    }

    /// Whether a window-server picture can be measured, and a skip when it cannot.
    ///
    /// The window server captures at the display's own pixel ratio and there is
    /// no way to ask it for another one, so on a display that is not Retina the
    /// picture comes back at one pixel per point while every rect the tests
    /// convert it with is written for two, and the measurement would be taken
    /// half a picture away from what it names. A process without the screen
    /// recording right is handed a blank picture rather than an error, which is
    /// the same kind of unusable: neither is a property of the code under test.
    ///
    /// - Parameters:
    ///   - image: the picture the window server returned.
    ///   - expectedScale: the pixels per point every measurement is written for.
    ///   - requiresContent: whether a picture of one colour is a failed capture.
    ///     A bare backdrop is one colour on purpose, so a picture a test takes
    ///     only to measure its card against passes false.
    /// - Throws: `XCTSkip` naming the reason the picture cannot be used.
    static func requireUsableCapture(
        _ image: Pixels,
        expectedScale: Int = 2,
        requiresContent: Bool = true
    ) throws {
        if requiresContent, image.isBlank {
            throw XCTSkip(
                "the window server returned a blank picture, which is what a process without the "
                    + "screen recording right is handed"
            )
        }
        let scale = Int(image.scale.rounded())
        if scale != expectedScale {
            throw XCTSkip(
                "the window server captured at \(scale) pixel\(scale == 1 ? "" : "s") per point "
                    + "and these measurements are written for \(expectedScale); it captures at the "
                    + "display's own ratio and cannot be asked for another one"
            )
        }
    }

    /// Skips the test when a raster of a hosted view cannot be measured.
    ///
    /// `cacheDisplay` draws a layer-backed hosting view through the backing
    /// store of the window it is in, and a window on a display that is not
    /// Retina has one pixel per point: the picture is then upscaled into the
    /// two-pixels-per-point bitmap the measurements are written for, its glow
    /// smears across the gap between two dots and the numbers belong to the
    /// display rather than to the code. `NSScreen.main` answers for a raster
    /// that is drawn without a window.
    ///
    /// - Parameter window: the window the view was rasterised in, or `nil` when
    ///   it was rasterised with no window and the display's own scale applies.
    /// - Throws: `XCTSkip` naming the scale the backing store has.
    @MainActor
    static func requireRetinaBacking(_ window: NSWindow? = nil) throws {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        if scale != 2 {
            throw XCTSkip(
                "the offscreen window's backing store is \(format(scale)) px per point and this "
                    + "raster is measured at 2; a display that is not Retina cannot provide it"
            )
        }
    }

    /// Skips the test when the session draws a reduced-motion card.
    ///
    /// The island's appearance is a spring that pours the card out of the notch,
    /// and a session that reports Reduce Motion draws a crossfade in place
    /// instead (`HUD.advanceAppearance`), which has no shape to measure. A test
    /// that measures the full motion reads the system setting unless it pins an
    /// override, so it says why it cannot run rather than measuring the fade.
    ///
    /// - Throws: `XCTSkip` when the system reports Reduce Motion.
    @MainActor
    static func requireFullMotion() throws {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            throw XCTSkip("the system reduces motion, and this test measures the full motion")
        }
    }

    /// A scale as it should read in a message: "1", not "1.0".
    private static func format(_ scale: CGFloat) -> String {
        scale == scale.rounded() ? String(Int(scale)) : String(Double(scale))
    }

    /// The one call that returns the composited window, out of the framework.
    private static func windowImage(_ window: CGWindowID) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        ), let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let function = unsafeBitCast(symbol, to: CreateImage.self)
        let options = CGWindowListOption.optionIncludingWindow
        let imageOptions: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        guard let unmanaged = function(.null, options.rawValue, window, imageOptions.rawValue)
        else { return nil }
        return unmanaged.takeRetainedValue()
    }

    /// The picture as an image, for writing it or drawing it.
    static func image(_ pixels: Pixels) -> CGImage? {
        var buffer = pixels.data
        return buffer.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: pixels.width,
                      height: pixels.height,
                      bitsPerComponent: 8,
                      bytesPerRow: pixels.width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return nil }
            return context.makeImage()
        }
    }

    /// The pixels of an image, in the capture's own layout.
    ///
    /// - Parameters:
    ///   - image: the image to read.
    ///   - scale: the pixels per point the image was drawn at, which a picture
    ///     the window server did not make carries on its own.
    static func pixels(from image: CGImage, scale: CGFloat = 1) -> Pixels? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return Pixels(width: width, height: height, data: buffer, scale: scale)
    }

    /// Writes a picture as a PNG.
    @discardableResult
    static func write(_ pixels: Pixels, to url: URL) -> Bool {
        guard let image = image(pixels) else { return false }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            return false
        }
        return (try? png.write(to: url, options: .atomic)) != nil
    }

    // MARK: - Measuring

    /// Runs the run loop, so the window server has something to composite.
    static func spin(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }

    /// The mean absolute difference between two pictures over a rectangle, in
    /// channel levels of 255.
    static func mad(_ first: Pixels, _ second: Pixels, rect: Rect) -> Double {
        guard first.width == second.width, first.height == second.height else { return .nan }
        let x0 = max(0, rect.x)
        let y0 = max(0, rect.y)
        let x1 = min(first.width, rect.x + rect.width)
        let y1 = min(first.height, rect.y + rect.height)
        guard x1 > x0, y1 > y0 else { return .nan }
        var sum = 0.0
        var count = 0
        for y in y0 ..< y1 {
            for x in x0 ..< x1 {
                let a = first.pixel(x, y)
                let b = second.pixel(x, y)
                sum += abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
                count += 3
            }
        }
        return count == 0 ? .nan : sum / Double(count)
    }

    /// The rectangle the pixels of one picture differ from another in.
    ///
    /// The card is found in its picture rather than assumed at a rect: the
    /// window server's capture can be at a different scale than the window's
    /// points, and a test that judged a fixed rect would be judging the wrong
    /// pixels on a display in a scaled mode.
    ///
    /// - Parameters:
    ///   - first: the picture with the view on it.
    ///   - second: the same canvas without the view.
    ///   - threshold: the sum of the three channel differences a pixel has to
    ///     exceed to count as changed, in levels of 255.
    /// - Returns: the rect covering every changed pixel, or nil when none did.
    static func changedBounds(
        _ first: Pixels,
        _ second: Pixels,
        threshold: Double = 2
    ) -> Rect? {
        guard first.width == second.width, first.height == second.height else { return nil }
        var minX = Int.max
        var minY = Int.max
        var maxX = Int.min
        var maxY = Int.min
        for y in 0 ..< first.height {
            for x in 0 ..< first.width {
                let a = first.pixel(x, y)
                let b = second.pixel(x, y)
                let difference = abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
                guard difference > threshold else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard minX <= maxX, minY <= maxY else { return nil }
        return Rect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The WCAG relative luminance of a colour given in levels of 255.
    static func luminance(_ colour: (Double, Double, Double)) -> Double {
        func linear(_ channel: Double) -> Double {
            let value = channel / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(colour.0) + 0.7152 * linear(colour.1) + 0.0722 * linear(colour.2)
    }

    /// The WCAG contrast ratio of two colours given in levels of 255.
    static func contrast(
        _ first: (Double, Double, Double),
        _ second: (Double, Double, Double)
    ) -> Double {
        let a = luminance(first)
        let b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The contrast a glyph box reads at.
    ///
    /// The box holds the glyphs and the surface between and around them, so the
    /// median luminance there is the surface the glyphs sit on and the brightest
    /// pixels are their strokes. WCAG takes those two, and the ratio is what the
    /// glyphs read at rather than what the ink's own colour would read at on a
    /// backdrop it is not drawn on.
    ///
    /// - Parameters:
    ///   - picture: the capture the glyphs are in.
    ///   - box: the glyphs' rect in the capture.
    /// - Returns: the surface's luminance, the ink's, and their contrast ratio.
    static func glyphContrast(
        _ picture: Pixels,
        box: Rect
    ) -> (background: Double, ink: Double, ratio: Double) {
        var values: [Double] = []
        for y in max(0, box.y) ..< min(picture.height, box.y + box.height) {
            for x in max(0, box.x) ..< min(picture.width, box.x + box.width) {
                values.append(luminance(picture.pixel(x, y)))
            }
        }
        guard !values.isEmpty else { return (0, 0, 0) }
        values.sort()
        let background = values[values.count / 2]
        let ink = values[min(values.count - 1, Int(Double(values.count) * 0.95))]
        return (background, ink, (ink + 0.05) / (background + 0.05))
    }
}
