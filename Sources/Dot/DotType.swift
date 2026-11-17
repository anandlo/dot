import AppKit
import CoreText
import SwiftUI

/// The one place the app's typeface is resolved.
///
/// Every surface is set in Switzer, a variable font whose only axis is weight,
/// 100 to 900 with Regular as the default instance. A variable font cannot be
/// picked by asking for a family and a size: a plain lookup always answers the
/// default instance, and the weight is an axis value written into the font
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
    /// The values are the face's own named instances: Extralight 200, Light
    /// 300, Regular 400, Medium 500, Semibold 600 and Bold 700. The axis runs
    /// from 100 to 900 and stops there, so anything above 900 clamps to the 900
    /// the axis allows, and the app never asks for more than 700. They are
    /// settled values, not a starting point to be re-tuned: the appearance was
    /// chosen on a rendered ladder at 22 points and again at 15, which is where
    /// a title and the body of the card sit.
    enum Weight: CaseIterable {
        case thin
        case light
        case regular
        case medium
        case semibold
        case bold

        /// The value written into the weight axis.
        var axisValue: CGFloat {
            switch self {
            case .thin: 200
            case .light: 300
            case .regular: 400
            case .medium: 500
            case .semibold: 600
            case .bold: 700
            }
        }

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
    /// which is Regular, `CTFontCopyVariation` answers nil, the PostScript name
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
    /// It is the name a plain lookup answers, and the axis is applied on top of
    /// it.
    private static let postScriptName = "SwitzerVariable-Regular"

    /// The family the face resolves to, which is what the fallback checks.
    static let familyName = "Switzer Variable"

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
        if let font = face(size: size, weight: weight) {
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
    /// Switzer's figures are tabular already: measured at 12 points and wght
    /// 500, each of the ten digits advances 6.912 points, a spread of 0.000, and
    /// the face carries no number-spacing feature to ask for. The feature is
    /// requested anyway, because the fallback is the system face, whose default
    /// figures are proportional: the request is what keeps a clock still in a
    /// checkout without the file, and what would keep it still in a face that
    /// only had tabular figures behind the feature. The result is cached beside
    /// the proportional fonts, so a view body pays a lookup.
    static func tabularNSFont(_ size: CGFloat, _ weight: Weight) -> NSFont {
        if let cached = tabularResolved.font(size: size, weight: weight) { return cached }
        let font = tabular(nsFont(size, weight), size: size)
        tabularResolved.store(font, size: size, weight: weight)
        return font
    }

    /// The same font with monospaced figures written into the descriptor.
    ///
    /// The feature settings have to be attached through Core Text: the AppKit
    /// descriptor attribute of the same name is dropped before the font is
    /// built, while a Core Text descriptor carries the setting into the face.
    private static func tabular(_ font: NSFont, size: CGFloat) -> NSFont {
        let base = font.fontDescriptor as CTFontDescriptor
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(base, [
            kCTFontFeatureSettingsAttribute: [
                [
                    kCTFontFeatureTypeIdentifierKey: numberSpacingType,
                    kCTFontFeatureSelectorIdentifierKey: monospacedNumbersSelector,
                ],
            ],
        ] as CFDictionary)
        guard let tabular = NSFont(descriptor: descriptor as NSFontDescriptor, size: size) else {
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
        if let font = face(size: size, weight: weight, named: name) {
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
