import AppKit
import CoreGraphics
import DotCore
@testable import Dot
import SwiftUI
import XCTest

/// The rewrite leaves follow the frame clock, not the card model's stale copy.
@MainActor
final class HUDRewriteFrameClockTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    func testRunningChipArcMovesWithTheFrameClock() throws {
        let card = runningCard()
        let first = try renderChip(card: card, ending: nil, time: 10.0)
        let second = try renderChip(card: card, ending: nil, time: 10.3)
        XCTAssertNotEqual(first, second, "the running arc stayed still as the frame clock advanced")
    }

    func testEndedChipArcIsGoneAfterTheFade() throws {
        let card = RewriteCard(original: "A transcript.", choices: RewriteStyle.builtIns)
        let ending = RewriteEnding(styleID: RewriteStyle.concise.id, at: 10)
        let faded = try renderChip(card: card, ending: ending, time: 10.15)
        let idle = try renderChip(card: card, ending: nil, time: 10.15)
        XCTAssertEqual(faded, idle, "the arc was still drawn after its fade")
    }

    func testDraftReachesFullInkAfterItsRamp() throws {
        var card = RewriteCard(original: "A transcript.", choices: RewriteStyle.builtIns)
        card.phase = .rewriting(styleID: RewriteStyle.concise.id, title: RewriteStyle.concise.title)
        card.draft = "New words."
        card.draftChunks = [RewriteDraftChunk(count: card.draft.count, time: 10)]
        let settled = try renderDraft(card: card, time: 10 + RewriteDraftRamp.duration + 0.02)
        let plain = try renderPlainText(card: card)
        XCTAssertEqual(settled, plain, "a settled draft chunk stayed dimmed")
    }

    private func runningCard() -> RewriteCard {
        var card = RewriteCard(original: "A transcript.", choices: RewriteStyle.builtIns)
        card.phase = .rewriting(styleID: RewriteStyle.concise.id, title: RewriteStyle.concise.title)
        return card
    }

    private func makeView(
        card: RewriteCard,
        ending: RewriteEnding?,
        time: Double
    ) -> HUDView {
        let model = HUDModel()
        let frame = HUDFrameModel()
        model.mode = .transcript(text: card.original, delivery: .copied, elapsed: "0:07")
        model.cardSize = HUDState.liveCard.size
        model.isVisible = true
        model.presence = 1
        model.content = 1
        model.material = .black
        model.rewrite = card
        model.rewriteEnding = ending
        frame.time = time
        frame.rewriteTime = time
        frame.level = 0.4
        frame.pulse = 0.25
        return HUDView(
            model: model,
            frame: frame,
            showsShadow: false,
            animated: false,
            actions: HUDPreview.previewActions,
            reduceMotionOverride: false
        )
    }

    private func renderChip(
        card: RewriteCard,
        ending: RewriteEnding?,
        time: Double
    ) throws -> Data {
        let view = makeView(card: card, ending: ending, time: time)
        return try rasterise(
            view.chipRow(card).padding(.horizontal, HUDTheme.padding),
            size: CGSize(width: 520, height: 44)
        )
    }

    private func renderDraft(card: RewriteCard, time: Double) throws -> Data {
        let view = makeView(card: card, ending: nil, time: time)
        return try rasterise(
            view.draftBody(card)
                .font(HUDTheme.transcriptFont)
                .foregroundStyle(HUDTheme.ink)
                .frame(width: 480, height: 80, alignment: .topLeading),
            size: CGSize(width: 480, height: 80)
        )
    }

    private func renderPlainText(card: RewriteCard) throws -> Data {
        return try rasterise(
            Text(card.visibleBodyText)
                .font(HUDTheme.transcriptFont)
                .foregroundStyle(HUDTheme.ink)
                .frame(width: 480, height: 80, alignment: .topLeading),
            size: CGSize(width: 480, height: 80)
        )
    }

    private func rasterise(_ view: some View, size: CGSize) throws -> Data {
        let hosting = NSHostingView(rootView: AnyView(
            view
                .frame(width: size.width, height: size.height)
                .environment(\.displayScale, 2)
                .environment(\.colorScheme, .dark)
        ))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * 2,
            pixelsHigh: Int(size.height) * 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw TestError.bitmap }
        bitmap.size = size
        hosting.cacheDisplay(in: NSRect(origin: .zero, size: size), to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw TestError.encoding
        }
        return data
    }

    enum TestError: Error {
        case bitmap
        case encoding
    }
}
