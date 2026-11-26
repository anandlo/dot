import AppKit
import CoreText
import DotCore
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
/// built its own descriptor would draw the file's default instance, Black, and
/// report nothing. Both are tested here as behaviour, not as source.
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

    /// The family resolves to Satoshi and not to a silent fallback.
    ///
    /// This is the assertion that catches the trap: the resolver answers the
    /// system font when the file is missing, and the app carries on, so the
    /// family name is the only thing that tells a real resolution from a
    /// fallback. The point size is the requested one times the optical factor,
    /// which is how every size in the app is drawn.
    func testTheFamilyResolvesToSatoshi() throws {
        let font = DotType.nsFont(13, .regular)
        XCTAssertEqual(font.familyName, DotType.familyName)
        XCTAssertEqual(font.familyName, "Satoshi Variable", "the resolver fell back to the system font")
        XCTAssertEqual(
            font.fontDescriptor.postscriptName,
            "SatoshiVariable-Bold_Regular",
            "the regular weight did not resolve the file's Regular instance"
        )
        XCTAssertTrue(DotType.isCustomFaceAvailable, "the last resolution did not use the bundled face")
        XCTAssertEqual(font.pointSize, 13 * DotType.opticalScale, accuracy: 0.001)
        XCTAssertEqual(DotType.opticalScale, 1.01, accuracy: 0.0001)
    }

    /// The file's default instance is Black, so the axis has to be set every
    /// time.
    ///
    /// The file declares its only axis from 300 to 900 with the maximum as the
    /// default, so a plain lookup draws Black and the body face is a variation
    /// on top of it. This is the fact that makes an unset axis a visible defect
    /// rather than a subtle one, which is why it is a test and not a comment.
    func testTheDefaultInstanceIsBlackSoTheAxisIsAlwaysSet() throws {
        let size: CGFloat = 15
        let base = try XCTUnwrap(NSFont(name: "SatoshiVariable-Bold", size: size * DotType.opticalScale))
        XCTAssertEqual(base.familyName, "Satoshi Variable")
        XCTAssertEqual(base.fontDescriptor.postscriptName, "SatoshiVariable-Bold")

        let atDefault = (Self.sample as NSString).size(withAttributes: [.font: base]).width
        let atRegular = (Self.sample as NSString)
            .size(withAttributes: [.font: DotType.nsFont(size, .regular)]).width
        let atBold = (Self.sample as NSString)
            .size(withAttributes: [.font: DotType.nsFont(size, .bold)]).width
        print("DotType default: plain lookup \(atDefault) pt, wght 400 \(atRegular) pt, wght 700 \(atBold) pt")

        XCTAssertGreaterThan(
            atRegular,
            0,
            "the body face drew nothing"
        )
        XCTAssertLessThan(
            atRegular,
            atDefault,
            "the plain lookup is not heavier than the body face, so the axis does not start at Black"
        )
        XCTAssertLessThan(
            atBold,
            atDefault,
            "the bold the app asks for is not lighter than the file's default"
        )
        // A lost axis is a ten percent jump in width, not a rounding error.
        XCTAssertGreaterThan(
            atDefault / atRegular,
            1.05,
            "the file's default instance is not the heaviest face, so an unset axis would go unnoticed"
        )

        // The axis the file declares, read from the face rather than from a
        // descriptor the app built.
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
            300,
            accuracy: 0.001,
            "the weight axis does not start at 300"
        )
        XCTAssertEqual(
            value(kCTFontVariationAxisDefaultValueKey, in: axis) ?? 0,
            900,
            accuracy: 0.001,
            "the weight axis does not default to 900"
        )
        XCTAssertEqual(
            value(kCTFontVariationAxisMaximumValueKey, in: axis) ?? 0,
            900,
            accuracy: 0.001,
            "the weight axis does not stop at 900"
        )
    }

    /// Six weights are six strictly increasing advances of the same sentence,
    /// and each one reports the axis value it was asked for.
    ///
    /// Six distinct PostScript names would prove the descriptors differ; the
    /// advance of one sentence proves the drawing followed the descriptor, which
    /// is the half that a string-keyed variation loses while still naming a
    /// face. The axis runs from 300 to 900 in one direction, so every weight has
    /// to be wider than the one below it.
    func testAllSixWeightsDrawStrictlyIncreasingAdvances() throws {
        let weights: [DotType.Weight] = [.thin, .light, .regular, .medium, .semibold, .bold]
        let size: CGFloat = 13
        let sentence = "Write as fast as you can think."
        func width(_ weight: DotType.Weight) -> CGFloat {
            (sentence as NSString).size(withAttributes: [.font: DotType.nsFont(size, weight)]).width
        }
        let widths = weights.map(width)
        let averages = widths.map { $0 / CGFloat(sentence.count) }
        let names = weights.map { DotType.nsFont(size, $0).fontDescriptor.postscriptName ?? "" }
        let variations = weights.map { weight -> Double? in
            let font = DotType.nsFont(size, weight) as CTFont
            guard let raw = CTFontCopyVariation(font) as NSDictionary? else { return nil }
            return (raw[0x7767_6874] as? NSNumber)?.doubleValue
        }
        print(
            "DotType weights at \(size) pt: "
                + zip(weights, widths).map { "\($0) \($1) pt (average \($1 / CGFloat(sentence.count)))" }
                .joined(separator: ", ")
                + " (names \(names), axes \(variations))"
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
                averages[index],
                averages[index - 1],
                "the average advance of \(weights[index]) is not wider than \(weights[index - 1]): "
                    + "\(averages[index]) pt against \(averages[index - 1]) pt for "
                    + "\"\(sentence)\" at \(size) pt"
            )
        }
        // The axis value the face carries is the one that was requested, not
        // the file's default of 900.
        for (index, weight) in weights.enumerated() {
            XCTAssertEqual(
                variations[index] ?? 0,
                Double(weight.axisValue),
                accuracy: 0.001,
                "\(weight) drew a face whose axis reads \(String(describing: variations[index]))"
            )
        }
        XCTAssertEqual(weights.map(\.axisValue), [300, 350, 400, 500, 600, 700])
    }

    /// The axis clamps at the heaviest value the file allows.
    ///
    /// The axis ends at 900, so a request above it has to draw the 900 face
    /// rather than fall back to the system font or to something else: the app
    /// never asks for more than 700, and a clamp that answered the wrong face
    /// would be silent.
    func testTheAxisClampsAboveNineHundred() throws {
        let size: CGFloat = 15
        let base = try XCTUnwrap(NSFont(name: "SatoshiVariable-Bold", size: size))
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
    /// numeric four-character code, and this test is the reason. The file's
    /// default is Black, so the untouched advance is the heaviest one.
    func testTheStringAxisKeyIsASilentNoOpAndMustNeverComeBack() throws {
        let size: CGFloat = 15
        func advance(_ font: NSFont) -> CGFloat {
            (Self.sample as NSString).size(withAttributes: [.font: font]).width
        }
        let base = try XCTUnwrap(NSFont(name: "SatoshiVariable-Bold", size: size))
        let atDefault = advance(base)

        let stringKeyed = try XCTUnwrap(
            NSFont(
                descriptor: base.fontDescriptor.addingAttributes([
                    .variation: ["wght": NSNumber(value: 300)],
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
                    .variation: [DotType.weightAxis: NSNumber(value: 300)],
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

    /// The body face is a shade narrower than the system face at the same size.
    ///
    /// The interface was measured and chosen on this: at 13 points, the size the
    /// rewrite rows and the body of the list are set in, a line of copy comes to
    /// a ratio of the same line in the system face that has to stay inside the
    /// band below. The band is the one the face was picked in; a republished
    /// file that pushed the face past it would invalidate every width in the HUD
    /// and the settings page. Satoshi is drawn 1 percent larger than the
    /// requested size, and at that size it lands just under the system face.
    func testTheRegularAdvanceIsAShadeNarrowerThanTheSystemFace() throws {
        let sentence = "Can you send Priya the updated notes"
        let satoshi = (sentence as NSString)
            .size(withAttributes: [.font: DotType.nsFont(13, .regular)]).width
        let system = (sentence as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        let ratio = satoshi / system
        print("DotType width at 13 pt: Satoshi \(satoshi) pt, system \(system) pt, ratio \(ratio)")
        XCTAssertGreaterThan(ratio, 0.90, "the face is narrower than the width it was chosen for")
        XCTAssertLessThan(ratio, 1.02, "the face is wider than the width it was chosen for")
    }

    // MARK: - The layout the interface was measured against

    /// One fixed UI string, the size and weight its site draws it at, and the
    /// width the same string had in Switzer at that size.
    private struct MeasuredString {
        let text: String
        let size: CGFloat
        let weight: CGFloat
        let tabular: Bool
        let switzer: CGFloat
    }

    /// The thirty longest fixed strings in the app, measured in Switzer.
    ///
    /// Each width was taken in the copy that still had Switzer, from the same
    /// string at the same size and weight, through the same descriptor
    /// construction the resolver uses. They are the layout this interface was
    /// chosen in, so a face, a weight ladder or an optical factor that moves one
    /// of them out of the band below has moved the product.
    private static let measured: [MeasuredString] = [
    MeasuredString(text: "Punctuation and line breaks match the app you dictate into. History keeps your original words.", size: 11.0, weight: 500, tabular: true, switzer: 464.37),
    MeasuredString(text: "Clicking the icon starts and stops recording instead of opening the menu.", size: 11.0, weight: 500, tabular: true, switzer: 360.94),
    MeasuredString(text: "The endpoint decides how long it keeps the audio. Dot keeps none.", size: 11.0, weight: 500, tabular: true, switzer: 329.44),
    MeasuredString(text: "The service needs no key. Turning it on is the whole setup.", size: 11.0, weight: 500, tabular: true, switzer: 286.60),
    MeasuredString(text: "Add the address of this service, then turn it on.", size: 11.0, weight: 500, tabular: true, switzer: 228.39),
    MeasuredString(text: "Hesitations, stutters and false starts are removed.", size: 11.0, weight: 500, tabular: true, switzer: 247.53),
    MeasuredString(text: "Flags PII, PHI, card numbers and offensive language.", size: 11.0, weight: 500, tabular: true, switzer: 259.66),
    MeasuredString(text: "Tags such as (laughter) and (applause) are kept.", size: 11.0, weight: 500, tabular: true, switzer: 239.33),
    MeasuredString(text: "Audio and transcripts are not kept for training.", size: 11.0, weight: 500, tabular: true, switzer: 227.02),
    MeasuredString(text: "When off, transcripts are copied to the clipboard.", size: 11.0, weight: 500, tabular: true, switzer: 241.95),
    MeasuredString(text: "Dates, times, currency, emails and phone numbers.", size: 11.0, weight: 500, tabular: true, switzer: 254.29),
    MeasuredString(text: "Speakers are labelled agent and customer.", size: 11.0, weight: 500, tabular: true, switzer: 212.37),
    MeasuredString(text: "Up to 32 speakers in multi-person audio.", size: 11.0, weight: 500, tabular: true, switzer: 199.64),
    MeasuredString(text: "Hesitations such as uh and um are kept.", size: 11.0, weight: 500, tabular: true, switzer: 197.14),
    MeasuredString(text: "ElevenLabs does not log or keep audio.", size: 11.0, weight: 500, tabular: true, switzer: 192.97),
    MeasuredString(text: "Formatting to prefer, such as ISO dates.", size: 11.0, weight: 500, tabular: true, switzer: 195.07),
    MeasuredString(text: "Sent with each request to help spelling.", size: 11.0, weight: 500, tabular: true, switzer: 194.43),
    MeasuredString(text: "Based on 12 recordings with this microphone", size: 11.0, weight: 500, tabular: true, switzer: 224.93),
    MeasuredString(text: "Deleting and sending always ask.", size: 11.0, weight: 500, tabular: true, switzer: 166.16),
    MeasuredString(text: "Common apps are formatted automatically", size: 13.0, weight: 500, tabular: false, switzer: 252.27),
    MeasuredString(text: "Send long recordings in parts of", size: 13.0, weight: 500, tabular: false, switzer: 186.06),
    MeasuredString(text: "Level meter calibration", size: 13.0, weight: 500, tabular: false, switzer: 135.32),
    MeasuredString(text: "Before an app changes something", size: 13.0, weight: 500, tabular: false, switzer: 201.63),
    MeasuredString(text: "Your words appear as you talk. Press the shortcut again to stop.", size: 13.5, weight: 500, tabular: false, switzer: 386.56),
    MeasuredString(text: "Your words appear as you talk. Let go of the shortcut to stop.", size: 13.5, weight: 500, tabular: false, switzer: 366.30),
    MeasuredString(text: "Requires ⌘, ⌥ or ⌃. A function key can be used alone.", size: 12.0, weight: 500, tabular: false, switzer: 291.06),
    MeasuredString(text: "Finished recordings appear here.", size: 11.5, weight: 500, tabular: false, switzer: 172.81),
    MeasuredString(text: "Nothing matches this search.", size: 11.5, weight: 500, tabular: false, switzer: 152.07),
    MeasuredString(text: "No styles. Use + Add style to create one.", size: 12.5, weight: 600, tabular: false, switzer: 227.58),
    MeasuredString(text: "Verbose JSON with timestamps", size: 12.5, weight: 500, tabular: true, switzer: 180.07),
    ]

    /// Every fixed string is still drawn inside the band the layout was chosen in.
    ///
    /// The band is two-sided and each side guards one failure.
    ///
    /// The ceiling is +3.5 percent, and what it catches is a lost weight axis:
    /// Satoshi's default instance is Black (900), so a resolution that never
    /// writes `wght` reads +6.0 to +9.1 percent and the 700 instance up to +5.8,
    /// while the widest correct string, the shortcut hint whose ⌘ ⌥ ⌃ fall back
    /// to Lucida Grande, reads +2.92.
    ///
    /// The floor is -1.7 percent, and what it catches is a lost optical factor:
    /// the same strings at factor 1.00 read down to -2.21 percent, while the
    /// chosen 1.01 reads -1.23 at its narrowest and stays inside.
    ///
    /// The measurement is of the face, at the size and weight each site asks
    /// for, without the tracking the tabular sites add: that tracking is a
    /// deliberate narrowing of the digits and is measured by
    /// ``testTheTabularDigitAdvanceIsThePublishedOne`` instead, so a change to it
    /// cannot be mistaken for a change of face.
    func testEveryFixedStringSitsInsideTheBandTheLayoutWasChosenIn() throws {
        var offsets: [(String, Double)] = []
        for row in Self.measured {
            let font = row.tabular
                ? DotType.tabularNSFont(row.size, Self.weight(row.weight))
                : DotType.nsFont(row.size, Self.weight(row.weight))
            let width = (row.text as NSString).size(withAttributes: [.font: font]).width
            offsets.append((row.text, Double(width / row.switzer - 1) * 100))
        }
        offsets.sort { $0.1 < $1.1 }
        print(
            "DotType band: min \(offsets.first?.1 ?? 0)% (\(offsets.first?.0.prefix(28) ?? "")), "
                + "median \(offsets[offsets.count / 2].1)%, max \(offsets.last?.1 ?? 0)% "
                + "(\(offsets.last?.0.prefix(28) ?? ""))"
        )
        XCTAssertEqual(offsets.count, 30)
        XCTAssertGreaterThanOrEqual(
            offsets.first?.1 ?? 0,
            -1.7,
            "a fixed string is narrower than the layout allows: \(offsets.first?.0 ?? "") at "
                + "\(offsets.first?.1 ?? 0) percent, which is what a lost optical factor reads"
        )
        XCTAssertLessThanOrEqual(
            offsets.last?.1 ?? 0,
            3.5,
            "a fixed string is wider than the layout allows: \(offsets.last?.0 ?? "") at "
                + "\(offsets.last?.1 ?? 0) percent, which is what a lost weight axis reads"
        )
    }

    /// The weight ladder's raw value as the enum case.
    private static func weight(_ raw: CGFloat) -> DotType.Weight {
        DotType.Weight(rawValue: raw) ?? .regular
    }

    /// A tabular number advances at the published fraction of its size.
    ///
    /// The face's `tnum` figures advance 0.66 em and the interface is laid out
    /// for 0.62, so the tabular face is drawn with the tracking ``DotType``
    /// publishes beside it. This is the measurement that pairs the two: two
    /// digits set with that tracking advance 0.62 of the size the face is drawn
    /// at, which is what the clock, the columns and the key badges were laid out
    /// for.
    func testTheTabularDigitAdvanceIsThePublishedOne() throws {
        let size: CGFloat = 12
        let clock = DotType.tabularNSFont(size, .medium)
        let tracking = DotType.tabularTracking(size: size, in: clock)
        let drawn = size * DotType.opticalScale
        print("DotType tracking: \(tracking) pt at \(size) requested, drawn \(drawn) pt")

        XCTAssertLessThan(tracking, 0, "the tabular face is not tracked back at all")
        XCTAssertEqual(
            tracking,
            (DotType.tabularAdvance - 0.66) * size * DotType.opticalScale,
            accuracy: 1e-9,
            "the published tracking is not the difference between the two advances"
        )
        XCTAssertEqual(DotType.tabularAdvance, 0.62, accuracy: 1e-9)

        let text = NSAttributedString(string: "00", attributes: [.font: clock, .kern: tracking])
        let advance = text.size().width
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        print(
            "DotType tabular advance: measured \(advance) pt, line bounds \(bounds) pt, "
                + "expected \(2 * DotType.tabularAdvance * drawn) pt"
        )
        XCTAssertEqual(
            advance,
            2 * DotType.tabularAdvance * drawn,
            accuracy: 0.02,
            "two tracked digits do not advance twice 0.62 of the drawn size"
        )
    }

    /// Tracking follows the font the site draws with, not the last resolution.
    ///
    /// The value used to come from the process-wide flag the resolver keeps, so a
    /// single fallback anywhere in the process set every clock's tracking to zero
    /// even where the bundled face was drawn. The font answers for itself: a
    /// fallback resolved first, then the clock's own tabular font, still reads the
    /// 0.62 em value, and the system face reads zero.
    func testTrackingFollowsTheDrawnFontNotTheLastResolution() throws {
        let size: CGFloat = 12
        let expected = (DotType.tabularAdvance - 0.66) * size * DotType.opticalScale

        // The clock's font first, so the cache is warm and the fallback below is
        // the only thing that has touched the process-wide flag since.
        _ = DotType.tabularNSFont(size, .medium)
        let fallback = DotType.nsFont(7.25, .thin, resolving: "SatoshiVariable-Missing")
        XCTAssertNotEqual(fallback.familyName, DotType.familyName, "the fallback resolved the face")
        XCTAssertFalse(DotType.isCustomFaceAvailable, "the process still reports the bundled face")

        let clock = DotType.tabularNSFont(size, .medium)
        XCTAssertEqual(clock.familyName, DotType.familyName, "the clock did not resolve the bundled face")
        XCTAssertEqual(
            DotType.tabularTracking(size: size, in: clock),
            expected,
            accuracy: 1e-9,
            "a fallback elsewhere in the process flattened the bundled face's tracking"
        )

        let system = NSFont.systemFont(ofSize: size, weight: .medium)
        XCTAssertEqual(
            DotType.tabularTracking(size: size, in: system),
            0,
            accuracy: 1e-12,
            "the system face was tracked, and its figures are already tabular"
        )
    }

    /// Tracking is applied only where the string is numbers and separators.
    ///
    /// Tracking cannot live in a font, so it is applied where the text is drawn,
    /// and only the sites whose string is digits and separators take it: the
    /// clocks and the durations, whose digits have to advance at the published
    /// fraction of their size. A site whose text can contain letters draws in the
    /// tabular face untracked, because tightening the letters of a title or a
    /// sentence is not what the digit advance is for.
    ///
    /// The numeric sites are declared here by the expression they draw, so a
    /// new clock or counter that forgets its tracking fails, and a title or a
    /// subtitle that grows one fails too.
    func testOnlyNumericTabularSitesCarryTracking() throws {
        let numeric: [String] = [
            "Dot/HUDView.swift|Text(elapsed)",
            "Dot/HUDView.swift|Text(elapsed)",
            "Dot/SettingsView.swift|Text(\"0:07\")",
            "Dot/WelcomeTour.swift|Text(\"00:03\")",
            "Dot/WelcomeTour.swift|Text(\"00:03\")",
            "Dot/WelcomeTour.swift|Text(HUDClock.string(for: max(0, elapsed)))",
        ]

        let sources = Self.root.appendingPathComponent("Sources", isDirectory: true)
        let files = try FileManager.default
            .subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        XCTAssertGreaterThan(files.count, 20, "the source tree was not found")

        var tokens: Set<String> = []
        let definition = try NSRegularExpression(
            pattern: "static var (\\w+): Font \\{ DotType\\.tabular(?:Font|NSFont)\\("
        )
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            let whole = text as NSString
            for match in definition.matches(in: text, range: NSRange(location: 0, length: whole.length)) {
                tokens.insert(whole.substring(with: match.range(at: 1)))
            }
        }
        XCTAssertEqual(
            tokens,
            ["clockFont", "titleFont", "subtitleFont"],
            "the tabular font tokens are not the ones this test knows about: \(tokens.sorted())"
        )

        let direct = try NSRegularExpression(pattern: "DotType\\.tabular(?:Font|NSFont)\\(")
        let throughFont = try NSRegularExpression(pattern: "\\.font\\((\\w+)\\.(\\w+)\\)")
        var tracked: [String] = []
        var untracked: [String] = []
        for file in files where file.hasPrefix("Dot/") || file.hasPrefix("DotCore/") {
            if file.hasSuffix("DotType.swift") { continue }
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                var isTabular = direct.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                if !isTabular,
                   let match = throughFont.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                    let name = (line as NSString).substring(with: match.range(at: 2))
                    isTabular = tokens.contains(name)
                }
                guard isTabular else { continue }
                // A token's own definition cannot carry tracking.
                if line.contains("static var ") { continue }
                // The tracking has to be the modifier that follows the font, not
                // one further down the same chain: a label's letter spacing can
                // sit six lines below a font it has nothing to do with.
                let window = lines[index ..< min(index + 3, lines.count)].joined(separator: "\n")
                let draws = lines[max(0, index - 1)].trimmingCharacters(in: .whitespaces)
                let site = "\(file)|\(draws)"
                if window.contains(".tracking(") {
                    tracked.append(site)
                } else {
                    untracked.append(site)
                }
            }
        }
        print("DotType tracked sites: \(tracked.sorted())")
        print("DotType untracked tabular sites: \(untracked.count)")
        XCTAssertEqual(
            tracked.sorted(),
            numeric.sorted(),
            "the tracked sites are not exactly the numeric ones"
        )
        XCTAssertEqual(tracked.count, 6, "the clock and duration sites are not the six declared here")
        for site in untracked {
            XCTAssertFalse(
                numeric.contains(site),
                "\(site) draws numbers and separators without its tracking"
            )
        }
    }

    // MARK: - The fallback

    /// A missing file answers the system face, at the same size and emphasis.
    ///
    /// The resolver is asked for a name it cannot resolve, which is the state a
    /// checkout without the font is in. The answer has to be the system face
    /// rather than an empty or unavailable font, because every view draws
    /// whatever this returns. It is deliberately not scaled by the optical
    /// factor: the system face is the one the layout was measured against, so
    /// scaling it would move the fallback off the grid the bundled face keeps.
    func testTheFallbackIsTheSystemFace() throws {
        let size: CGFloat = 7.25
        let fallback = DotType.nsFont(size, .thin, resolving: "SatoshiVariable-Missing")
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
        XCTAssertEqual(rest.familyName, "Satoshi Variable", "the face did not come back")
        XCTAssertEqual(rest.pointSize, 13 * DotType.opticalScale, accuracy: 0.001)
        XCTAssertTrue(DotType.isCustomFaceAvailable)
    }

    // MARK: - The figures

    /// The digits of the tabular face share one advance, and the plain ones do
    /// not.
    ///
    /// A clock whose digits are ten different widths shifts as the seconds
    /// change. Satoshi's default figures are proportional, so every place the
    /// app draws a number that changes is set in ``DotType/tabularFont(_:_:)``,
    /// and this is the measurement that token stands on: at 12 points and wght
    /// 500, the ten digits have to agree within a hundredth of a point while the
    /// plain face spans more than two points between its narrowest and widest.
    func testTheDigitsOfTheTabularFaceShareOneAdvance() throws {
        let size: CGFloat = 12
        let font = DotType.tabularNSFont(size, .medium)
        func advances(_ face: NSFont) -> [CGFloat] {
            (0 ... 9).map { digit in
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: "\(digit)", attributes: [.font: face])
                )
                return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            }
        }
        let widths = advances(font)
        let plainWidths = advances(DotType.nsFont(size, .medium))
        let spread = (widths.max() ?? 0) - (widths.min() ?? 0)
        let plainSpread = (plainWidths.max() ?? 0) - (plainWidths.min() ?? 0)
        print(
            "DotType digits at \(size) pt wght 500: tabular "
                + widths.map { String(format: "%.4f", $0) }.joined(separator: ", ")
                + " (spread \(spread)); plain "
                + plainWidths.map { String(format: "%.4f", $0) }.joined(separator: ", ")
                + " (spread \(plainSpread))"
        )
        XCTAssertEqual(widths.count, 10)
        XCTAssertLessThanOrEqual(
            spread,
            0.01,
            "the ten digits do not share one advance, so a clock set in this face would jitter: "
                + "\(widths)"
        )
        XCTAssertGreaterThan(
            plainSpread,
            2,
            "the plain face's figures are already tabular, so the tabular token proves nothing: "
                + "\(plainWidths)"
        )
    }

    // MARK: - The SwiftUI bridge

    /// A SwiftUI font bridged from the resolved system font keeps the axis.
    ///
    /// `Font.custom` looks a family up by name and answers the default instance
    /// every time, so the app bridges `Font(nsFont)`. The resolved font is read
    /// back through `Font.resolve`: the family has to be Satoshi and the weight
    /// has to be the one asked for, not the file's Black.
    @MainActor
    func testTheSwiftUIBridgeKeepsTheVariation() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Font.resolve is not available before macOS 26")
        }
        let context = EnvironmentValues().fontResolutionContext
        let resolvedRegular = DotType.font(15, .regular).resolve(in: context).ctFont
        let regular = resolvedRegular as NSFont
        XCTAssertEqual(regular.familyName, "Satoshi Variable")
        XCTAssertEqual(
            regular.fontDescriptor.postscriptName,
            DotType.nsFont(15, .regular).fontDescriptor.postscriptName,
            "the SwiftUI font resolved to a different face than the system font it was bridged from"
        )

        let resolvedSemibold = DotType.font(15, .semibold).resolve(in: context).ctFont
        let semibold = resolvedSemibold as NSFont
        XCTAssertEqual(semibold.familyName, "Satoshi Variable")
        XCTAssertNotEqual(
            semibold.fontDescriptor.postscriptName,
            regular.fontDescriptor.postscriptName,
            "the bridge collapsed two weights onto one face, which is what a custom font does"
        )
    }

    // MARK: - The drawn face

    /// The transcript is drawn in the resolved face, measured off the pixels.
    ///
    /// A test that only checked `HUDTheme.transcriptFont` would prove the token
    /// was configured, not that the card drew it: a fallback anywhere between
    /// the token and the text view would leave the suite green and the product
    /// in another face. So the card is drawn off every display at two pixels per
    /// point and the ink of the transcript is measured.
    ///
    /// Two things are asserted. The ink has to be the advance the resolver
    /// measured, within the side bearings the last glyph drops. And it has to be
    /// narrower than the file's own default instance by a wide margin: the face
    /// ships Black as its default, so a card that lost the weight axis would
    /// draw ten percent wider and this is the assertion that catches it. The
    /// bundled face and the system face are within one percent of each other at
    /// this size, so ink width can no longer tell them apart; the family and
    /// axis tests above carry that half, and ``testOnlyDotTypeAsksTheSystemForAFont``
    /// keeps every call site inside the resolver.
    @MainActor
    func testTheTranscriptIsDrawnInTheResolvedFace() throws {
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

        let resolvedAdvance = (sentence as NSString)
            .size(withAttributes: [.font: DotType.nsFont(15, .regular)]).width
        let defaultAdvance = (
            sentence as NSString
        ).size(withAttributes: [
            .font: NSFont(name: "SatoshiVariable-Bold", size: 15 * DotType.opticalScale)
                ?? DotType.nsFont(15, .regular),
        ]).width

        print(
            "DotType render: drawn ink \(drawn) pt, resolved advance \(resolvedAdvance) pt, "
                + "default-instance advance \(defaultAdvance) pt"
        )

        XCTAssertEqual(
            drawn,
            resolvedAdvance,
            accuracy: resolvedAdvance * 0.03,
            "the drawn transcript (\(drawn) pt) is not the advance the resolver measured "
                + "(\(resolvedAdvance) pt), so the face resolved to something else"
        )
        XCTAssertLessThan(
            drawn,
            defaultAdvance * 0.97,
            "the transcript drew \(drawn) pt where the file's default instance draws "
                + "\(defaultAdvance) pt: the card is not setting the weight axis"
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

    // MARK: - The glyphs the face does not carry

    /// Every character of the modifier line is drawn, by the face or by the
    /// cascade.
    ///
    /// Satoshi has no macOS modifier signs and no Japanese and Cyrillic, so the
    /// line has to be completed by CoreText's cascade: Lucida Grande for the
    /// signs, PingFang for the Japanese, Helvetica for the Cyrillic. Tofu is
    /// glyph zero of whatever font the run resolved, so a single zero would mean
    /// a box where a character should be. The line is also rendered when
    /// `DOT_TYPE_RENDER_DIR` is set, so the result can be looked at rather than
    /// only counted.
    @MainActor
    func testEveryGlyphInTheModifierLineIsDrawn() throws {
        _ = NSApplication.shared
        let line = "Command \u{2318} Option \u{2325} Shift \u{21E7} Control \u{2303} Return \u{23CE} "
            + "\u{65E5}\u{672C}\u{8A9E} \u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}"
        let font = DotType.nsFont(13, .regular)
        let attributed = NSAttributedString(string: line, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        let runs = CTLineGetGlyphRuns(ctLine) as! [CTRun]

        var families: [String] = []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as? NSFont
            families.append(runFont?.familyName ?? "?")
            XCTAssertFalse(
                glyphs.contains(0),
                "a character in \"\(line)\" drew glyph zero, which is the empty box: \(glyphs) "
                    + "from \(runFont?.familyName ?? "?")"
            )
        }
        print("DotType cascade: \(families)")
        XCTAssertEqual(
            families.first,
            DotType.familyName,
            "the line did not start in the bundled face"
        )
        for expected in ["Lucida Grande", "PingFang SC", "Helvetica"] {
            XCTAssertTrue(
                families.contains(expected),
                "the cascade did not reach \(expected) for the characters Satoshi does not carry: \(families)"
            )
        }

        let value = DotMigration.environment("RENDER_TYPE_DIR") ?? ""
        guard !value.isEmpty else { return }
        let directory = URL(fileURLWithPath: value, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = try Self.render(textLine: attributed, width: 620, height: 32)
        let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("type-cascade.png"), options: .atomic)
        print("DotType cascade render: \(directory.appendingPathComponent("type-cascade.png").path)")
    }

    /// One line of text drawn into a bitmap at two pixels per point.
    @MainActor
    private static func render(textLine: NSAttributedString, width: CGFloat, height: CGFloat) throws -> NSBitmapImageRep {
        let scale = 2
        let view = Text(AttributedString(textLine))
            .foregroundStyle(Color.white)
            .frame(width: width, height: height, alignment: .leading)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = OffscreenWindow(size: CGSize(width: width, height: height), styleMask: [.borderless])
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(width) * scale,
                pixelsHigh: Int(height) * scale,
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
        bitmap.size = CGSize(width: width, height: height)
        host.cacheDisplay(in: NSRect(x: 0, y: 0, width: width, height: height), to: bitmap)
        window.contentView = nil
        window.orderOut(nil)
        return bitmap
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
    /// used to stand outside the rule are gone: every number the app draws that
    /// changes, lines up or reports a count is set in
    /// ``DotType/tabularFont(_:_:)``, which is part of ``DotType`` and not a
    /// system font. The scan is by line, and the expected list is empty, so a
    /// new call anywhere fails here.
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
