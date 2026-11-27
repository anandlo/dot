import CoreGraphics
import os
import QuartzCore
import XCTest
@testable import Dot

final class LiveVisualizerLayerTests: XCTestCase {
    /// Core Animation makes copies of copies of this layer with `init(layer:)`.
    /// A copy that wrapped the draw callback again would add one closure context
    /// per generation; 0.1.0-beta crashed releasing such a chain after a long
    /// recording. Copies must share the stored callback object itself.
    func testCopiesShareTheStoredCallbackInsteadOfWrappingIt() throws {
        let original = LiveVisualizerLayer()
        original.setOnDraw { _, _ in }
        let stored = try XCTUnwrap(original.debugDrawCallbackIdentity)

        var layer = original
        for _ in 0..<3 {
            layer = LiveVisualizerLayer(layer: layer)
        }

        XCTAssertEqual(layer.debugDrawCallbackIdentity, stored)
    }

    func testACopyStillReportsItsDrawsToTheOriginalCallback() throws {
        let draws = OSAllocatedUnfairLock(initialState: 0)
        let original = LiveVisualizerLayer()
        original.setOnDraw { _, _ in draws.withLock { $0 += 1 } }
        original.enqueue(VisualizerFrame())
        let copy = LiveVisualizerLayer(layer: LiveVisualizerLayer(layer: original))
        copy.bounds = CGRect(x: 0, y: 0, width: 40, height: 20)

        let context = try XCTUnwrap(CGContext(
            data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        copy.draw(in: context)

        XCTAssertEqual(draws.withLock { $0 }, 1)
    }

    func testClearingTheCallbackRemovesIt() throws {
        let layer = LiveVisualizerLayer()
        layer.setOnDraw { _, _ in }
        layer.setOnDraw(nil)
        XCTAssertNil(layer.debugDrawCallbackIdentity)
    }
}
