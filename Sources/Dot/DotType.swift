import AppKit
import CoreText
import SwiftUI

/// The one place the app's typeface is resolved.
///
/// Every surface is set in Satoshi, a variable font whose only axis is weight,
/// 300 to 900 with Black (900) as the default instance. A variable font cannot
/// be picked by asking for a family and a size: a plain lookup always answers
/// the default instance, and the weight is an axis value written into the font
/// descriptor. There is a single place that builds it, and this is it. A call
/// site that asked the system for a font instead would draw a different face in
/// the middle of a sentence, which is why the rule is one helper and no
/// exceptions outside ``tabularFont(_:_:)``, which the places that draw numbers
/// use so the digits cannot jitter.
///
/// The face is not shipped in the repository. It is copied into the app bundle
/// by `scripts/build.sh` because the licence allows embedding and forbids
/// redistribution, so a checkout without it still builds: every call falls back
/// to the system font at the nearest system weight and the app looks like it
/// did before the typeface.
enum DotType {
    /// The six weights the app is designed in.
    ///
    /// The values are written into the weight axis, which runs from 300 to 900.
    /// Satoshi has a named instance at 300, 400, 500, 700 and 900 and no master
    /// below 300, so the ladder starts at the axis floor: thin is 300, the
    /// Light instance, and light at 350 and semibold at 600 are interpolated
    /// between the instances either side of them. Nothing above 900 is asked
    /// for, and the axis clamps there. They are settled values, not a starting
    /// point to be re-tuned: the appearance was chosen on a rendered ladder at
    /// 22 points and again at 15, which is where a title and the body of the
    /// card sit.
    enum Weight: CGFloat, CaseIterable {
        case thin = 300
        case light = 350
        case regular = 400
        case medium = 500
        case semibold = 600
        case bold = 700

        /// The value written into the weight axis.
        var axisValue: CGFloat { rawValue }

        /// The system weight that stands in when the face is not in the bundle.
        ///
        /// It is the nearest weight the system has, so a checkout without the
        /// font still reads with the same emphasis rather than as one flat
        /// regular.
        var systemWeight: NSFont.Weight {
            switch self {
            case .thin: .thin
            case .light: .light
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }
    }

    /// The four-character code of the weight axis, as a number.
    ///
    /// This must be the numeric code rather than the string "wght". A string
    /// key is accepted into a font descriptor and stored, and then matched
    /// against nothing: every advance stays at the face's default instance,
    /// which is Black, `CTFontCopyVariation` answers nil, the PostScript name
    /// never changes, and no error is raised anywhere. The silent no-op is the
    /// reason this constant exists once, here, and the reason no other file
    /// may build a variation dictionary.
    static let weightAxis = NSNumber(value: 0x7767_6874)

    /// Number-spacing in the font descriptor's feature settings.
    private static let numberSpacingType = 6
    /// The selector of monospaced figures within number-spacing.
    private static let monospacedNumbersSelector = 0

    /// The PostScript name of the default instance the file ships.
    ///
    /// That instance is Black, the axis maximum, so this name on its own draws
    /// the heaviest face in the family. Every resolution applies the axis on top
    /// of it; nothing in the app draws this name unresolved.
    private static let postScriptName = "SatoshiVariable-Bold"

    /// The family the face resolves to, which is what the fallback checks.
    static let familyName = "Satoshi Variable"

    /// The factor every requested size is multiplied by before the face is made.
    ///
    /// Satoshi stands 0.91 of Switzer's x-height at wght 400 and its average
    /// lowercase advance is 0.955 of Switzer's, both read from the two files at
    /// the same weight, while its word space is 1.385 times Switzer's, so a line
    /// of real copy comes out wider than the letter-run ratio predicts. Measured
    /// over the thirty longest fixed strings in the app, at the weight each site
    /// draws it, 1.01 keeps every one of them inside -1.23 to +2.92 percent of
    /// the width the interface was laid out at, and lifts the drawn x-height from 0.911 to 0.921 of the old one.
    /// The system fallback is not scaled: it stands in for the face the layout
    /// was measured against, so scaling it would move the one path the factor
    /// does not need to touch.
    static let opticalScale: CGFloat = 1.01

    /// The tabular digit advance the interface is drawn to, in em.
    ///
    /// The face's `tnum` figures advance 0.66 em. At the size a clock or a
    /// column of numbers is drawn the HUD and the settings pages were laid out
    /// for a narrower figure, so ``tabularTracking(size:)`` takes the difference
    /// back out.
    static let tabularAdvance: CGFloat = 0.62

    /// The digit advance the face's own `tnum` figures carry, in em.
    private static let bundledTabularAdvance: CGFloat = 0.66

    /// The fonts already resolved, so a view body does not rebuild one a frame.
    private static let resolved = Resolver()

    /// The fonts resolved with monospaced figures, cached the same way.
    private static let tabularResolved = Resolver()

    /// Whether the last resolution used the bundled face.
    ///
    /// A missing font is not an error the app can show: it falls back and
    /// carries on. Tests read this to tell a real resolution from a silent
    /// fallback, so a suite that forgot to register the file cannot pass by
    /// drawing the system font.
    static var isCustomFaceAvailable: Bool { resolved.usedCustomFace }

    /// The face at a point size and a weight, for SwiftUI.
    ///
    /// The font is bridged from the resolved system font rather than built with
    /// `Font.custom`: a custom font is looked up by family name, which answers
    /// the file's default instance every time and loses the axis.
    static func font(_ size: CGFloat, _ weight: Weight) -> Font {
        Font(nsFont(size, weight))
    }

    /// The face at a point size and a weight, for AppKit.
    ///
    /// Everything that measures text goes through this same call as everything
    /// that draws it. A measurement taken in one face and drawn in another
    /// sizes a card for words it is not going to hold.
    static func nsFont(_ size: CGFloat, _ weight: Weight) -> NSFont {
        if let cached = resolved.font(size: size, weight: weight) { return cached }
        if let font = face(size: size * opticalScale, weight: weight) {
            resolved.store(font, size: size, weight: weight)
            return font
        }
        resolved.fellBack()
        return NSFont.systemFont(ofSize: size, weight: weight.systemWeight)
    }

    /// The face at a point size and a weight, with tabular figures, for SwiftUI.
    ///
    /// Every site that draws a number a person reads while it changes uses
    /// this: the card's clock, the key badges, the labels that carry a key or a
    /// shortcut, the settings footnote and the shortcut field. A clock set in a
    /// proportional face jitters as the seconds change.
    static func tabularFont(_ size: CGFloat, _ weight: Weight) -> Font {
        Font(tabularNSFont(size, weight))
    }

    /// The face at a point size and a weight, with tabular figures, for AppKit.
    ///
    /// Satoshi's default figures are proportional: measured in the file at 12
    /// points and wght 500 the ten digits span 4.37 to 8.32 points, which is a
    /// clock that jumps and a column of numbers that does not line up. The
    /// face carries `tnum`, which substitutes a monospaced set at 660 units, so
    /// the feature is requested from Core Text and every digit then advances
    /// 8.32 points at the 12.6 the resolver asks for. The result is cached
    /// beside the proportional fonts, so a view body pays a lookup.
    static func tabularNSFont(_ size: CGFloat, _ weight: Weight) -> NSFont {
        if let cached = tabularResolved.font(size: size, weight: weight) { return cached }
        let font = tabular(nsFont(size, weight), weight: weight)
        // Only a font that came from the bundled face is kept: a fallback stored
        // here would answer every later call for the same size and weight, so the
        // face would stay invisible for the rest of the process. The font itself
        // answers the question, not the process-wide last-resolution flag: a
        // fallback for another size must not stop this size being cached.
        if font.familyName == familyName {
            tabularResolved.store(font, size: size, weight: weight)
        }
        return font
    }

    /// The tracking that belongs with ``tabularFont(_:_:)`` at the same size.
    ///
    /// Tracking cannot live in a font: Core Text descriptors carry variations and
    /// feature settings and nothing else, and `NSFont` has no tracking property.
    /// It is applied where the text is drawn, so every site that draws with the
    /// tabular face pairs the font with this value and the two travel together.
    ///
    /// The face that was actually used decides the value, not the process-wide
    /// result of the last resolution: a fallback somewhere else in the process
    /// must not flatten the tracking of a clock that is drawn in the bundled
    /// face. Reading the font's own family is the only answer that cannot go
    /// stale.
    ///
    /// - Parameters:
    ///   - size: the same size that was passed to ``tabularFont(_:_:)``.
    ///   - font: the font the site draws with, tabular or not.
    /// - Returns: `(0.62 - 0.66) x size x opticalScale` points between two
    ///   digits, which is the difference between the face's own figure and the
    ///   advance the columns were laid out for. Zero when the font is not the
    ///   bundled family, whose figures are tabular already and were never
    ///   measured against this face.
    static func tabularTracking(size: CGFloat, in font: NSFont) -> CGFloat {
        guard font.familyName == familyName else { return 0 }
        return (tabularAdvance - bundledTabularAdvance) * size * opticalScale
    }

    /// The same font with monospaced figures written into the descriptor.
    ///
    /// The feature settings have to be attached through Core Text: the AppKit
    /// descriptor attribute of the same name is dropped before the font is
    /// built, while a Core Text descriptor carries the setting into the face.
    /// The size comes from the resolved font rather than from the caller, so the
    /// optical factor applied there is not undone here.
    private static func tabular(_ font: NSFont, weight: Weight) -> NSFont {
        let base = font.fontDescriptor as CTFontDescriptor
        var attributes: [CFString: Any] = [
            kCTFontFeatureSettingsAttribute: [
                [
                    kCTFontFeatureTypeIdentifierKey: numberSpacingType,
                    kCTFontFeatureSelectorIdentifierKey: monospacedNumbersSelector,
                ],
            ],
        ]
        // The weight is written again on the copy rather than relied on to
        // survive it: a descriptor rebuilt for the figures alone answers the
        // file's default instance, which is Black, and a clock set in Black is a
        // different clock.
        if font.familyName == familyName {
            attributes[kCTFontVariationAttribute] = [weightAxis: NSNumber(value: weight.axisValue)]
        }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(base, attributes as CFDictionary)
        guard let tabular = NSFont(descriptor: descriptor as NSFontDescriptor, size: font.pointSize) else {
            return font
        }
        return tabular
    }

    /// The same resolution against a named face rather than the bundled one.
    ///
    /// The two-argument call above is the whole app; this one exists so a test
    /// can walk the path a checkout without the font file takes. That path
    /// cannot be reached by unregistering the file from a running process:
    /// CoreText keeps answering a name it has already resolved, so the fallback
    /// would never be entered and the test would prove nothing. It bypasses the
    /// cache for the same reason, and reports what it did through
    /// ``isCustomFaceAvailable`` exactly as the cached path does.
    ///
    /// - Parameters:
    ///   - size: the point size.
    ///   - weight: the weight to write into the axis.
    ///   - name: the PostScript name to resolve; a name that is not the bundled
    ///     file's is refused by the family check.
    static func nsFont(_ size: CGFloat, _ weight: Weight, resolving name: String) -> NSFont {
        if let font = face(size: size * opticalScale, weight: weight, named: name) {
            resolved.store(font, size: size, weight: weight)
            return font
        }
        resolved.fellBack()
        return NSFont.systemFont(ofSize: size, weight: weight.systemWeight)
    }

    /// The bundled face, or nil when the font is not registered.
    private static func face(size: CGFloat, weight: Weight) -> NSFont? {
        face(size: size, weight: weight, named: postScriptName)
    }

    /// The face a PostScript name resolves to, with the weight axis applied.
    ///
    /// The family check is what makes a fallback loud rather than silent: a
    /// name that resolves to something other than this family is refused, so a
    /// file that registered under a different name cannot slip an unrelated
    /// face into the app.
    private static func face(size: CGFloat, weight: Weight, named name: String) -> NSFont? {
        guard let base = NSFont(name: name, size: size) else { return nil }
        let descriptor = base.fontDescriptor.addingAttributes([
            .variation: [weightAxis: NSNumber(value: weight.axisValue)],
        ])
        guard let font = NSFont(descriptor: descriptor, size: size) else { return nil }
        guard font.familyName == familyName else { return nil }
        return font
    }

    /// Registers every font file in a directory for this process.
    ///
    /// The packaged app is covered by `ATSApplicationFontsPath`, which the build
    /// script writes into the bundle. This is the belt-and-braces path for a
    /// bundle launched in a way that skipped it, and for tests, which are not
    /// in the app bundle at all and must point at the repository's directory.
    ///
    /// Registering a file that is already registered is not a failure: the
    /// font manager answers "already registered" and the face is present, which
    /// is the only thing the caller asked. Calling it twice is therefore safe.
    ///
    /// - Parameter directory: the directory holding the `.ttf`, `.otf` or
    ///   `.ttc` files to register.
    /// - Returns: whether the family resolved afterwards.
    @discardableResult
    static func registerFonts(at directory: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for file in files where fontExtensions.contains(file.pathExtension.lowercased()) {
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error)
        }
        let available = NSFont(name: postScriptName, size: 13)?.familyName == familyName
        resolved.setAvailable(available)
        return available
    }

    /// The file types the font manager can register.
    private static let fontExtensions: Set<String> = ["ttf", "otf", "ttc"]

    /// The resolved fonts and whether the face was found, behind one lock.
    ///
    /// A resolution happens from view bodies, which SwiftUI may build off the
    /// main thread, so the cache cannot be a plain static variable. Only a
    /// successful resolution is cached: a miss has to be retried, or a font
    /// registered after the first draw would never be seen.
    private final class Resolver: @unchecked Sendable {
        private let lock = NSLock()
        private var fonts: [Key: NSFont] = [:]
        private var customFace = false

        private struct Key: Hashable {
            let size: CGFloat
            let weight: Weight
        }

        var usedCustomFace: Bool {
            lock.lock()
            defer { lock.unlock() }
            return customFace
        }

        func font(size: CGFloat, weight: Weight) -> NSFont? {
            lock.lock()
            defer { lock.unlock() }
            guard let font = fonts[Key(size: size, weight: weight)] else { return nil }
            customFace = true
            return font
        }

        func store(_ font: NSFont, size: CGFloat, weight: Weight) {
            lock.lock()
            defer { lock.unlock() }
            fonts[Key(size: size, weight: weight)] = font
            customFace = true
        }

        func fellBack() {
            lock.lock()
            defer { lock.unlock() }
            customFace = false
        }

        func setAvailable(_ available: Bool) {
            lock.lock()
            defer { lock.unlock() }
            customFace = available
        }
    }
}
