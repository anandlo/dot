import Foundation

/// The small text helpers every connector result uses.
///
/// Tool results are read by a model and, often, shown to a person. A consistent
/// shape (a count, then one line per item) is easier for both than each
/// connector inventing its own prose.
enum ResultText {
    /// A counted list.
    ///
    /// - Parameters:
    ///   - heading: what the items are, singular: "reminder".
    ///   - items: the lines, already formatted.
    ///   - empty: the sentence to return when there are none.
    /// - Returns: the result text.
    static func list(heading: String, items: [String], empty: String) -> String {
        guard !items.isEmpty else { return empty }
        let plural = items.count == 1 ? heading : heading + "s"
        return "\(items.count) \(plural):\n" + items.map { "- " + $0 }.joined(separator: "\n")
    }

    /// One line of an item: a title and any details, joined with a middle dot.
    ///
    /// - Parameter parts: the fields, in reading order.
    /// - Returns: the line.
    static func line(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " | ")
    }

    /// A path with `~` for the home folder, which is shorter and says whose file
    /// it is.
    ///
    /// - Parameter path: an absolute path.
    /// - Returns: the path as a person would write it.
    static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
