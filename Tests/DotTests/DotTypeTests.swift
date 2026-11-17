import AppKit
import CoreText
import SwiftUI
import XCTest
@testable import Dot

/// The typeface the whole app is set in, proved at the places it can fail
/// silently.
///
/// A missing font file does not raise: the resolver falls back and the app looks
/// like it did before, so a suite that forgot to register the face would pass
/// while measuring the system font. And a variation requested with the string
/// "wght" is accepted into the descriptor and then ignored, so a call site that
/// built its own descriptor would draw the file's default instance, Regular,
/// and report nothing. Both are tested here as behaviour, not as source.
final class DotTypeTests: XCTestCase {
    // MARK: - Registration

    /// The package root, found from this file.
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let available = FontFixture.register()
        XCTAssertTrue(
            available,
            "the repository font did not register from \(FontFixture.directory.path). "
                + "The face is not committed: run scripts/fetch-fonts.sh before the suite."
        )
    }

    // MARK: - The face

    /// The family resolves to Switzer and not to a silent fallback.
    ///
    /// This is the assertion that catches the trap: the resolver answers the
    /// system font when the file is missing, and the app carries on, so the
    /// family name is the only thing that tells a real resolution from a
    /// fallback.
    func testTheFamilyResolvesToSwitzer() throws {
        let font = DotType.nsFont(13, .regular)
        XCTAssertEqual(font.familyName, DotType.familyName)
        XCTAssertEqual(font.familyName, "Switzer Variable", "the resolver fell back to the system font")
        XCTAssertTrue(DotType.isCustomFaceAvailable, "the last resolution did not use the bundled face")
        XCTAssertEqual(font.pointSize, 13, accuracy: 0.001)
    }

    /// The file's default instance is Regular, not one of the display weights.
    ///
    /// Every weight the app draws is a variation on top of the file's default,
    /// which the file declares as wght 400, so the face a plain lookup answers
    /// is the body face. A file republished with a different default would make
    /// the unweighted lookup draw something the app never chose, which is why
    /// this is a test rather than a comment.
    func testTheDefaultInstanceIsRegularFourHundred() throws {
        let base = try XCTUnwrap(NSFont(name: "SwitzerVariable-Regular", size: 15))
        XCTAssertEqual(base.familyName, "Switzer Variable")
        XCTAssertEqual(base.fontDescriptor.postscriptName, "SwitzerVariable-Regular")

        let atDefault = (Self.sample as NSString).size(withAttributes: [.font: base]).width
        let atRegular = (Self.sample as NSString)
            .size(withAttributes: [.font: DotType.nsFont(15, .regular)]).width
        let atBold = (Self.sample as NSString)
            .size(withAttributes: [.font: DotType.nsFont(15, .bold)]).width
        print("DotType default: plain lookup \(atDefault) pt, wght 400 \(atRegular) pt, wght 700 \(atBold) pt")

        XCTAssertEqual(
            atDefault,
            atRegular,
            accuracy: 0.0001,
            "the plain lookup is not the file's Regular instance, so the axis does not start at 400"
        )
        XCTAssertGreaterThan(
            atBold,
            atDefault,
            "the bold the app asks for is not heavier than the file's default, so the axis is not "
                + "a weight axis running upwards from Regular"
        )

        // The axis the file declares, read from the face rather than from a
        // descriptor the app built: the minimum, the default and the maximum are
        // the file's own, and the default is what a plain lookup draws.
        let axes = try XCTUnwrap(
            CTFontCopyVariationAxes(base as CTFont) as? [[String: Any]],
            "the face reports no variation axis"
        )
        func value(_ key: CFString, in axis: [String: Any]) -> Double? {
            (axis[key as String] as? NSNumber)?.doubleValue
        }
        print("DotType axes: \(axes)")
        XCTAssertEqual(axes.count, 1, "the face carries more than one axis")
        let axis = try XCTUnwrap(axes.first)
        let identifier = value(kCTFontVariationAxisIdentifierKey, in: axis) ?? 0
        XCTAssertEqual(
            UInt32(identifier),
            0x7767_6874,
            "the only axis is \(Self.tag(UInt32(identifier))) rather than weight"
        )
        XCTAssertEqual(
            value(kCTFontVariationAxisMinimumValueKey, in: axis) ?? 0,
            100,
            accuracy: 0.001,
            "the weight axis does not start at 100"
        )
        XCTAssertEqual(
            value(kCTFontVariationAxisDefaultValueKey, in: axis) ?? 0,
            400,
            accuracy: 0.001,
            "the weight axis does not default to 400"
        )
        XCTAssertEqual(
            value(kCTFontVariationAxisMaximumValueKey, in: axis) ?? 0,
            900,
            accuracy: 0.001,
            "the weight axis does not stop at 900"
        )
    }

    /// Six weights are six different widths of the same string.
    ///
    /// Six distinct PostScript names would prove the descriptors differ; the
    /// advance of one string proves the drawing followed the descriptor, which
    /// is the half that a string-keyed variation loses while still naming a
    /// face. Each weight has to be wider than the one below it, because the
    /// axis runs from 100 to 900 in one direction.
    func testAllSixWeightsDrawDistinctAdvanceWidths() throws {
        let weights: [DotType.Weight] = [.thin, .light, .regular, .medium, .semibold, .bold]
        func width(_ weight: DotType.Weight) -> CGFloat {
            (Self.sample as NSString).size(withAttributes: [.font: DotType.nsFont(15, weight)]).width
        }
        let widths = weights.map(width)
        let names = weights.map { DotType.nsFont(15, $0).fontDescriptor.postscriptName ?? "" }
        print(
            "DotType weights: "
                + zip(weights, widths).map { "\($0) \($1) pt" }.joined(separator: ", ")
                + " (names \(names))"
        )
        XCTAssertEqual(
            Set(widths).count,
            weights.count,
            "the six weights did not draw six widths: \(widths)"
        )
        for (index, name) in names.enumerated() {
            XCTAssertFalse(name.isEmpty, "\(weights[index]) resolved to no PostScript name")
        }
        for index in 1 ..< weights.count {
            XCTAssertGreaterThan(
                widths[index] - widths[index - 1],
                1,
                "\(weights[index]) is not heavier than \(weights[index - 1]): "
                    + "\(widths[index]) pt against \(widths[index - 1]) pt for the same string at 15 pt"
            )
        }
    }

    /// The axis clamps at the heaviest value the file allows.
    ///
    /// The axis ends at 900, so a request above it has to draw the 900 face
    /// rather than fall back to the default or to the system font: the app
    /// never asks for more than 700, and a clamp that answered Regular would be
    /// silent.
    func testTheAxisClampsAboveNineHundred() throws {
        let size: CGFloat = 15
        let base = try XCTUnwrap(NSFont(name: "SwitzerVariable-Regular", size: size))
        func width(at value: CGFloat) -> CGFloat {
            let descriptor = base.fontDescriptor.addingAttributes([
                .variation: [DotType.weightAxis: NSNumber(value: value)],
            ])
            let font = NSFont(descriptor: descriptor, size: size) ?? base
            return (Self.sample as NSString).size(withAttributes: [.font: font]).width
        }
        let atNineHundred = width(at: 900)
        let above = width(at: 1000)
        print("DotType clamp: wght 900 \(atNineHundred) pt, wght 1000 \(above) pt")
        XCTAssertEqual(
            above,
            atNineHundred,
            accuracy: 0.0001,
            "a request above the axis maximum did not clamp to 900"
        )
        XCTAssertGreaterThan(atNineHundred, width(at: 700), "900 is not heavier than 700")
    }

    /// A variation keyed by the string "wght" does nothing at all.
    ///
    /// This is a fact about this OS and SDK, and it is recorded as a test so
    /// nobody reintroduces the form: the descriptor keeps the key, every advance
    /// is identical to the file's default instance, and no error is raised. The
    /// app builds its variation dictionary from ``DotType/weightAxis``, a
    /// numeric four-character code, and this test is the reason.
    func testTheStringAxisKeyIsASilentNoOpAndMustNeverComeBack() throws {
        let size: CGFloat = 15
        func advance(_ font: NSFont) -> CGFloat {
            (Self.sample as NSString).size(withAttributes: [.font: font]).width
        }
        let base = try XCTUnwrap(NSFont(name: "SwitzerVariable-Regular", size: size))
        let atDefault = advance(base)

        let stringKeyed = try XCTUnwrap(
            NSFont(
                descriptor: base.fontDescriptor.addingAttributes([
                    .variation: ["wght": NSNumber(value: 200)],
                ]),
                size: size
            )
        )
        XCTAssertEqual(
            advance(stringKeyed),
            atDefault,
            accuracy: 0.0001,
            "the string-keyed variation changed the advance, so the silent no-op documented here "
                + "no longer holds and DotType's numeric axis must be re-checked"
        )
        XCTAssertEqual(
            stringKeyed.fontDescriptor.postscriptName,
            base.fontDescriptor.postscriptName,
            "the string-keyed variation resolved a different face, which contradicts the no-op"
        )

        // The numeric key on the same descriptor does move the axis, which is
        // what makes the two forms distinguishable at all.
        let numeric = try XCTUnwrap(
            NSFont(
                descriptor: base.fontDescriptor.addingAttributes([
                    .variation: [DotType.weightAxis: NSNumber(value: 200)],
                ]),
                size: size
            )
        )
        XCTAssertNotEqual(
            advance(numeric),
            atDefault,
            accuracy: 0.0001,
            "the numeric axis left the advance at the default, so neither form applies the weight"
        )
        XCTAssertNotEqual(
            numeric.fontDescriptor.postscriptName,
            base.fontDescriptor.postscriptName,
            "the numeric axis resolved the default face"
        )
    }

    // MARK: - The width the interface was chosen for

    /// Switzer is a shade narrower than the system face at the same size.
    ///
    /// The interface was measured and chosen on this: at 13 points, the size
    /// the rewrite rows and the body of the list are set in, a line of copy
    /// comes to a ratio of the same line in the system face that has to stay
    /// inside the band below. The band is the one the face was picked in; a
    /// republished file that pushed the face past it would invalidate every
    /// width in the HUD and the settings page.
    func testTheRegularAdvanceIsAShadeNarrowerThanTheSystemFace() throws {
        let sentence = "Can you send Priya the updated notes"
        let switzer = (sentence as NSString)
            .size(withAttributes: [.font: DotType.nsFont(13, .regular)]).width
        let system = (sentence as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        let ratio = switzer / system
        print("DotType width at 13 pt: Switzer \(switzer) pt, system \(system) pt, ratio \(ratio)")
        XCTAssertGreaterThan(ratio, 0.90, "the face is narrower than the width it was chosen for")
        XCTAssertLessThan(ratio, 1.02, "the face is wider than the width it was chosen for")
    }

    // MARK: - The fallback

    /// A missing file answers the system face, at the same size and emphasis.
    ///
    /// The resolver is asked for a name it cannot resolve, which is the state a
    /// checkout without the font is in. The answer has to be the system face
    /// rather than an empty or unavailable font, because every view draws
    /// whatever this returns.
    func testTheFallbackIsTheSystemFace() throws {
        let size: CGFloat = 7.25
        let fallback = DotType.nsFont(size, .thin, resolving: "SwitzerVariable-Missing")
        let system = NSFont.systemFont(ofSize: size, weight: .thin)
        XCTAssertNotEqual(fallback.familyName, DotType.familyName, "a missing name resolved the face")
        XCTAssertEqual(fallback.familyName, system.familyName, "the fallback is not the system face")
        XCTAssertEqual(fallback.pointSize, size, accuracy: 0.001)
        XCTAssertFalse(DotType.isCustomFaceAvailable, "the fallback reported the bundled face")
        // A name that resolves but belongs to another family is refused rather
        // than drawn: that is what keeps a wrongly registered file out of the
        // app instead of quietly setting it in Helvetica.
        let foreign = DotType.nsFont(size, .thin, resolving: "Helvetica")
        XCTAssertNotEqual(foreign.familyName, "Helvetica", "a font from another family was accepted")

        // The real face comes back for the next resolution, so the two states
        // are told apart and not latched.
        let rest = DotType.nsFont(13, .regular)
        XCTAssertEqual(rest.familyName, "Switzer Variable", "the face did not come back")
        XCTAssertTrue(DotType.isCustomFaceAvailable)
    }

    // MARK: - The figures

    /// The digits of the tabular face share one advance.
    ///
    /// A clock whose digits are ten different widths shifts as the seconds
    /// change. Every place the app draws a number that changes is set in
    /// ``DotType/tabularFont(_:_:)``, and this is the measurement that token
    /// stands on: at 12 points and wght 500, the ten digits have to agree
    /// within a hundredth of a point.
    func testTheDigitsOfTheTabularFaceShareOneAdvance() throws {
        let size: CGFloat = 12
        let font = DotType.tabularNSFont(size, .medium)
        var widths: [CGFloat] = []
        for digit in 0 ... 9 {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: "\(digit)", attributes: [.font: font])
            )
            widths.append(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        }
        let plain = DotType.nsFont(size, .medium)
        var plainWidths: [CGFloat] = []
        for digit in 0 ... 9 {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: "\(digit)", attributes: [.font: plain])
            )
            plainWidths.append(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        }
        let spread = (widths.max() ?? 0) - (widths.min() ?? 0)
        print(
            "DotType digits at \(size) pt wght 500: tabular "
                + widths.map { String(format: "%.4f", $0) }.joined(separator: ", ")
                + " (spread \(spread)); plain "
                + plainWidths.map { String(format: "%.4f", $0) }.joined(separator: ", ")
        )
        XCTAssertEqual(widths.count, 10)
        XCTAssertLessThanOrEqual(
            spread,
            0.01,
            "the ten digits do not share one advance, so a clock set in this face would jitter: "
                + "\(widths)"
        )
    }

    // MARK: - The SwiftUI bridge

    /// A SwiftUI font bridged from the resolved system font keeps the axis.
    ///
    /// `Font.custom` looks a family up by name and answers the default instance
    /// every time, so the app bridges `Font(nsFont)`. The resolved font is read
    /// back through `Font.resolve`: the family has to be Switzer and the weight
    /// has to be the one asked for, not the file's Regular.
    @MainActor
    func testTheSwiftUIBridgeKeepsTheVariation() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Font.resolve is not available before macOS 26")
        }
        let context = EnvironmentValues().fontResolutionContext
        let resolvedRegular = DotType.font(15, .regular).resolve(in: context).ctFont
        let regular = resolvedRegular as NSFont
        XCTAssertEqual(regular.familyName, "Switzer Variable")
        XCTAssertEqual(
            regular.fontDescriptor.postscriptName,
            DotType.nsFont(15, .regular).fontDescriptor.postscriptName,
            "the SwiftUI font resolved to a different face than the system font it was bridged from"
        )

        let resolvedSemibold = DotType.font(15, .semibold).resolve(in: context).ctFont
        let semibold = resolvedSemibold as NSFont
        XCTAssertEqual(semibold.familyName, "Switzer Variable")
        XCTAssertNotEqual(
            semibold.fontDescriptor.postscriptName,
            regular.fontDescriptor.postscriptName,
            "the bridge collapsed two weights onto one face, which is what a custom font does"
        )
    }

    // MARK: - The drawn face

    /// The transcript is drawn in Switzer, measured off the pixels.
    ///
    /// A test that only checked `HUDTheme.transcriptFont` would prove the token
    /// was configured, not that the card drew it: a fallback anywhere between
    /// the token and the text view would leave the suite green and the product
    /// in the system font. So the card is drawn off every display at two pixels
    /// per point and the ink of the transcript is measured, then compared with
    /// the same sentence drawn in the system face at the same size. Switzer is
    /// about 0.976 of the system width at 15 points, so the two are apart by
    /// far more than the measurement's own error, in the opposite direction
    /// from a wider face.
    @MainActor
    func testTheTranscriptIsDrawnInSwitzerNotConfiguredToBe() throws {
        _ = NSApplication.shared
        let sentence = "The quick brown fox jumps over the lazy dog."
        let size = HUD.transcriptSize(text: sentence)

        let model = HUDModel()
        model.isVisible = true
        model.presence = 1
        model.content = 1
        model.time = 1.2
        model.material = .black
        model.mode = .transcript(text: sentence, delivery: .pasted, elapsed: "0:07", destination: "Mail")
        model.cardSize = size

        let card = HUDView(
            model: model,
            showsShadow: false,
            animated: false,
            actions: HUDPreview.previewActions
        )
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)

        // The card's body only: the header above it carries its own text, the
        // badge and the clock, and none of that is the transcript.
        let bodyTop = CGFloat(HUDTheme.headerHeight + 1) * 2
        let drawn = try inkWidth(of: card, size: size, skippingTopPixels: bodyTop)

        let system = Text(sentence)
            .font(Font(NSFont.systemFont(ofSize: 15)))
            .foregroundStyle(HUDTheme.ink)
            .environment(\.colorScheme, .dark)
        let referenceSize = CGSize(width: size.width, height: 60)
        let systemDrawn = try inkWidth(of: system, size: referenceSize, skippingTopPixels: 0)

        let switzerAdvance = (sentence as NSString)
            .size(withAttributes: [.font: DotType.nsFont(15, .regular)]).width
        let systemAdvance = (sentence as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 15)]).width

        print(
            "DotType render: Switzer ink \(drawn) pt (advance \(switzerAdvance) pt), "
                + "system ink \(systemDrawn) pt (advance \(systemAdvance) pt), "
                + "ratio \(drawn / systemDrawn)"
        )

        // Narrower ink than the system face is the signature of the bundled
        // face; the same test before the typeface changed asserted the opposite
        // sign, because that face was wider.
        XCTAssertLessThan(
            drawn,
            systemDrawn * 0.99,
            "the transcript drew \(drawn) pt where the system font drew \(systemDrawn) pt: "
                + "the card is not drawing Switzer"
        )
        XCTAssertGreaterThan(
            drawn,
            systemDrawn * 0.90,
            "the transcript drew \(drawn) pt, narrower than any reading of the bundled face: "
                + "the card is not drawing the typeface"
        )
        XCTAssertEqual(
            drawn,
            switzerAdvance,
            accuracy: switzerAdvance * 0.12,
            "the drawn transcript (\(drawn) pt) is not the Switzer advance (\(switzerAdvance) pt), "
                + "so the face resolved to something else"
        )
    }

    /// The width the drawn ink of a view occupies, in points.
    ///
    /// The view is drawn into a two pixel per point bitmap inside a window the
    /// window server never puts on a display, and the ink is the extent of the
    /// pixels brighter than the surface behind them.
    @MainActor
    private func inkWidth<V: View>(
        of view: V,
        size: CGSize,
        skippingTopPixels top: CGFloat
    ) throws -> CGFloat {
        let scale = 2
        let host = NSHostingView(rootView: view.environment(\.displayScale, CGFloat(scale)))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = OffscreenWindow(size: size, styleMask: [.borderless])
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width) * scale,
                pixelsHigh: Int(size.height) * scale,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            "the render could not be allocated"
        )
        bitmap.size = size
        host.cacheDisplay(in: NSRect(origin: .zero, size: size), to: bitmap)
        window.contentView = nil
        window.orderOut(nil)

        var first: Int?
        var last: Int?
        for y in Int(top) ..< bitmap.pixelsHigh {
            for x in 0 ..< bitmap.pixelsWide {
                guard let colour = bitmap.colorAt(x: x, y: y), colour.alphaComponent > 0.5 else { continue }
                let lit = colour.brightnessComponent > 0.45
                guard lit else { continue }
                first = min(first ?? x, x)
                last = max(last ?? x, x)
            }
        }
        let low = try XCTUnwrap(first, "the view drew no ink")
        let high = try XCTUnwrap(last)
        return CGFloat(high - low + 1) / CGFloat(scale)
    }

    /// The string the weight ladder is measured on.
    private static let sample = "Hamburgefonstiv 0123"

    /// A four-character code as the string it stands for.
    private static func tag(_ code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? "\(code)"
    }

    // MARK: - The rule

    /// Every font call in the app goes through ``DotType``, with no exceptions.
    ///
    /// A direct system font is a different face in the middle of a sentence, so
    /// it is a test failure and not a style note. The monospaced sites that
    /// used to stand outside the rule are gone: Switzer's figures are tabular,
    /// so the clock, the key badges, the labels, the footnote and the shortcut
    /// field are all set in ``DotType/tabularFont(_:_:)``, which is part of
    /// ``DotType`` and not a system font. The scan is by line, and the expected
    /// list is empty, so a new call anywhere fails here.
    func testOnlyDotTypeAsksTheSystemForAFont() throws {
        struct Site: Hashable {
            let file: String
            let line: String
        }
        let expected: [Site] = []

        let sources = Self.root.appendingPathComponent("Sources", isDirectory: true)
        let files = try FileManager.default
            .subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        XCTAssertGreaterThan(files.count, 20, "the source tree was not found")

        var found: [Site] = []
        for file in files {
            // The helper is the one place allowed to ask the system for a font:
            // it is the fallback.
            if file.hasSuffix("DotType.swift") { continue }
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for raw in text.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.contains(".system(") || line.contains("systemFont") else { continue }
                // A message role is not a font.
                if line.contains(".system(system") || line.contains("func system(") { continue }
                found.append(Site(file: (file as NSString).lastPathComponent, line: line))
            }
        }

        func key(_ site: Site) -> String { "\(site.file): \(site.line)" }
        XCTAssertEqual(
            found.map(key).sorted(),
            expected.map(key).sorted(),
            "the system font call sites are not empty. Found: "
                + found.map(key).joined(separator: " | ")
        )
    }
}
