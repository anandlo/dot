import Foundation

/// The version this build reports.
///
/// `VERSION` at the package root is the only place a version is spelled out.
/// `scripts/build.sh` reads it into `CFBundleShortVersionString`, and this type
/// reads that back, so the About window, the update check and the log all
/// report the same string the bundle advertises.
///
/// A binary that was not assembled into a bundle — `swift run`, a test host —
/// has no `CFBundleShortVersionString` to read. It reports ``unknown`` and logs
/// the miss rather than carrying a second copy of the version that could drift
/// from `VERSION`.
public enum ProductVersion {
    /// What the bundle declares, or ``unknown`` when there is no bundle.
    public static let current: String = resolve()

    /// The string reported when the bundle declares no version.
    ///
    /// It is deliberately not a version: a build that cannot say which version
    /// it is must not look like one that can.
    public static let unknown = "unknown"

    /// A SemVer version as people read it: `1.2.0-beta.3` is "1.2.0 Beta 3",
    /// `1.0.0-rc.2` is "1.0.0 RC 2". Build metadata after `+` is dropped, and
    /// anything without a prerelease part, such as ``unknown``, is unchanged.
    public static func displayName(_ version: String) -> String {
        let withoutBuild = version.split(separator: "+", maxSplits: 1).first.map(String.init) ?? version
        guard let hyphen = withoutBuild.firstIndex(of: "-") else { return withoutBuild }
        let core = withoutBuild[..<hyphen]
        let prerelease = withoutBuild[withoutBuild.index(after: hyphen)...]
        guard !core.isEmpty, !prerelease.isEmpty else { return withoutBuild }
        var words: [String] = []
        for identifier in prerelease.split(separator: ".") {
            let letters = identifier.prefix { $0.isLetter }
            let rest = identifier.dropFirst(letters.count)
            if !letters.isEmpty {
                words.append(prereleaseLabel(String(letters)))
            }
            if !rest.isEmpty {
                words.append(String(rest))
            }
        }
        return ([String(core)] + words).joined(separator: " ")
    }

    private static func prereleaseLabel(_ word: String) -> String {
        switch word.lowercased() {
        case "rc": "RC"
        default: word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }
    }

    private static func resolve() -> String {
        let declared = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trimmed = declared?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            Log.shared.warn("version.missing", [
                "bundle": .string(Bundle.main.bundleIdentifier ?? "none"),
            ])
            return unknown
        }
        return trimmed
    }
}
