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
