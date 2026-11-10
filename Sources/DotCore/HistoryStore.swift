import Foundation

/// The transcripts Dot remembers between launches.
///
/// The file holds the last few transcripts, newest first. It is written on a
/// background queue and read once at launch; it never holds audio and never
/// holds a credential.
public enum HistoryStore {
    /// How many transcripts are kept.
    public static let limit = 20

    /// The file the history lives in.
    ///
    /// It sits beside the configuration, so both move together when the
    /// product's folder is migrated.
    public static func defaultURL() -> URL {
        DotConfig.directoryURL().appendingPathComponent("history.json")
    }

    /// Reads the history.
    public static func load(from url: URL = defaultURL()) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let items = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Array(items.prefix(limit))
    }

    /// Writes the history.
    public static func save(_ items: [String], to url: URL = defaultURL()) {
        let trimmed = Array(items.prefix(limit))
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(trimmed)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.shared.error("history.save.failed", ["error": .string(error.localizedDescription)])
        }
    }

    /// The history with one more transcript at the front.
    ///
    /// A transcript that is already at the front is not added twice: pasting
    /// the same text again should not fill the menu with copies.
    public static func adding(_ text: String, to items: [String]) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        var next = items.filter { $0 != trimmed }
        next.insert(trimmed, at: 0)
        return Array(next.prefix(limit))
    }
}
