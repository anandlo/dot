import Foundation

/// Where the archive's Markdown files are written.
///
/// The folder is the person's choice, so it survives being moved or renamed: a
/// stored bookmark is resolved before the stored path is believed. The app is
/// not sandboxed, so the bookmark is a plain one. Its only job is to follow the
/// folder, not to grant access to it.
public enum TranscriptArchiveFolder {
    /// The folder the archive uses when none has been chosen.
    ///
    /// - Parameter home: the home directory to build the path under.
    /// - Returns: `Documents/Dot` inside it.
    public static func defaultURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Dot", isDirectory: true)
    }

    /// The options a stored bookmark is resolved with.
    ///
    /// `withoutUI` so a folder behind a permission or sign-in panel cannot put
    /// that panel on screen while the archive chain waits for an answer, and
    /// `withoutMounting` so a volume that is not mounted reports itself
    /// unreachable instead of pulling a server connection up in the middle of a
    /// dictation. An unreachable folder then takes the same missing-folder path
    /// as one the person deleted: the write fails, the history is already
    /// written, and the Settings row says why.
    public static let resolutionOptions: URL.BookmarkResolutionOptions = [
        .withoutUI,
        .withoutMounting,
    ]

    /// The folder to write into, and a bookmark to store when the stored one is
    /// out of date.
    ///
    /// A bookmark that cannot be resolved is not fatal: the folder may have been
    /// on a volume that is not mounted, and the path the person chose is the
    /// next best answer. The default is used only when neither is stored.
    ///
    /// - Parameters:
    ///   - settings: the archive's settings as they stand.
    ///   - home: the home directory the default folder is built under.
    ///   - resolving: how a stored bookmark is turned into a folder. It is the
    ///     default in the app; a test passes its own to see the options and to
    ///     stand in for a volume that cannot be reached.
    /// - Returns: the folder to write into, and fresh bookmark data when the
    ///   stored bookmark reported itself stale. The data is `nil` whenever the
    ///   bookmark needs no rewrite.
    public static func resolve(
        _ settings: TranscriptArchiveSettings,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        resolving: (Data, URL.BookmarkResolutionOptions, inout Bool) throws -> URL = { data, options, stale in
            try URL(
                resolvingBookmarkData: data,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        }
    ) -> (url: URL, refreshedBookmark: Data?) {
        if let stored = settings.folderBookmark {
            var stale = false
            if let resolved = try? resolving(stored, resolutionOptions, &stale) {
                // A stale bookmark still resolves, but to a location the system
                // had to reason its way to. Rewriting it now is what keeps the
                // next launch cheap and the following move findable.
                let refreshed = stale ? (try? resolved.bookmarkData(options: [])) : nil
                return (resolved, refreshed)
            }
        }
        if let path = settings.folderPath, !path.isEmpty {
            return (URL(fileURLWithPath: path, isDirectory: true), nil)
        }
        return (defaultURL(home: home), nil)
    }

    /// The bookmark worth storing after a background refresh, or `nil`.
    ///
    /// The refresh is resolved from the settings a background task started
    /// with. If the person has chosen another folder since, the fresh bookmark
    /// describes a folder the configuration no longer names, and storing it
    /// would silently put the archive back where they moved it from.
    ///
    /// - Parameters:
    ///   - refreshed: the bookmark the resolution produced, when it was stale.
    ///   - started: the settings the refresh was resolved from.
    ///   - current: the settings as they stand now.
    public static func refresh(
        _ refreshed: Data?,
        resolvedFrom started: TranscriptArchiveSettings,
        current: TranscriptArchiveSettings
    ) -> Data? {
        guard let refreshed else { return nil }
        guard current.folderPath == started.folderPath,
              current.folderBookmark == started.folderBookmark
        else { return nil }
        return refreshed
    }
}

/// Why the archive left a day file alone.
///
/// Both cases keep the same promise: the write replaces a whole file, so a file
/// Dot cannot be sure it has read is never written. The transcript is already in
/// the history, which is the copy the app reads back.
public enum TranscriptArchiveError: Error, Equatable, LocalizedError {
    /// The day file is there but could not be read, so its words are unknown.
    case unreadableDay(String)
    /// Another writer changed the day file while Dot was rebuilding it.
    case concurrentWrite(String)
    /// Two sections carry the same instant and the words do not choose between
    /// them.
    case ambiguous(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableDay(let path):
            "Dot could not read \(path), so nothing was written to it."
        case .concurrentWrite(let path):
            "\(path) changed while Dot was writing it, so nothing was written."
        case .ambiguous(let path):
            "\(path) holds two takes from the same instant, so nothing was written for either."
        }
    }

    /// The one word the log records for this refusal.
    ///
    /// A log line is read by a person looking for a pattern, so the reason is a
    /// stable token rather than a sentence that changes with a path.
    public var logReason: String {
        switch self {
        case .unreadableDay: "read"
        case .concurrentWrite: "concurrent"
        case .ambiguous: "ambiguous"
        }
    }
}

/// What the last write to the archive did.
///
/// The Settings row reads it to say whether the folder is being written to. It
/// is deliberately small: a date, or the reason the write failed, and never the
/// words that were being written.
public enum TranscriptArchiveStatus: Equatable, Sendable {
    /// Nothing has been written since the app started.
    case idle
    /// The last write finished at the given moment.
    case saved(Date)
    /// The last write failed, with a description that names the fault and not
    /// the transcript.
    case failed(String)
}

/// One Markdown file per local day, holding every take delivered that day and
/// the rewrites made from it.
///
/// The archive is a second copy, never the record: the history is what Dot
/// reads back, and a folder that cannot be written changes nothing about a
/// delivery. It is an actor because two writes to the same day file must not
/// interleave - the whole file is read, changed and replaced - and because the
/// work belongs off the main actor.
///
/// The file is the person's as much as Dot's. Everything already in it is kept
/// byte for byte, including notes typed above the title or inside a take, and
/// the only region ever regenerated is the version list of the one take being
/// updated. Two limits follow from that shape and are deliberate: text typed
/// under a take *after* its first `### ` heading is regenerated, because that
/// region is the take's version list; and `NSFileCoordinator` is not used, so a
/// folder inside an iCloud Drive is written without announcing the change to
/// the person's other devices.
///
/// A take is identified by the instant it was delivered, never by the text of
/// its anchor: an anchor is formatted in whatever time zone was in force when
/// it was written, and a person who flies somewhere between a take and its
/// rewrite still owns one take, not two.
public actor TranscriptArchive {
    /// Where the section this process wrote for one take lives.
    private struct Written {
        let file: URL
        let instant: Date
        let text: String
    }

    /// How many versions this process last wrote for one take.
    private struct Counted {
        let file: URL
        let instant: Date
        let count: Int
    }

    /// One change to a day file: the new text, and the anchor of the take it
    /// changed.
    private typealias Change = (String) throws -> (content: String, anchor: String)?

    /// What the file's size and date looked like when it was read.
    private struct Stamp: Equatable {
        let size: Int
        let modified: Date?
    }

    /// The file moved between the read and the commit, so the change has to be
    /// re-applied to what is now there.
    private struct CommitRace: Error {}

    /// The calendar the day file, the heading and the anchor are written in.
    ///
    /// The app passes nothing, which leaves this reading
    /// `Calendar.autoupdatingCurrent` on every write: a person who flies
    /// somewhere and dictates again gets the take in the day they are now in.
    /// A test passes a fixed calendar, or one it changes mid-session.
    private let currentCalendar: @Sendable () -> Calendar
    /// The engine's one time dependency.
    ///
    /// Both record calls are stamped by the caller, which is the moment the
    /// words were delivered rather than the moment the disk answered, so
    /// nothing here reads the clock today. It is injected anyway so the engine
    /// owns a single clock: a call that ever needs to know "now" cannot reach
    /// for `Date()` behind the caller's back or behind a test's back.
    private let now: @Sendable () -> Date
    private let home: URL
    /// A hook that runs at the commit boundary, just before the rename.
    ///
    /// Nothing in the app passes one. It exists so a test can play the part of a
    /// second writer - another editor, another device - and prove that the
    /// change written underneath Dot is not lost.
    private let beforeCommit: (@Sendable (URL) -> Void)?
    /// The takes this process has placed, so a rewrite made minutes later lands
    /// under the section that was written for it rather than under a second copy
    /// of the same words in another day.
    ///
    /// It is the session's short memory and is never trimmed: a rewrite arrives
    /// seconds after its take, and a take this list has forgotten is still found
    /// by its instant in the day files.
    private var written: [Written] = []
    /// How many versions this process last wrote for each take.
    ///
    /// Two snapshots of one card can arrive out of order, and the older one
    /// must not replace the newer list it knows nothing about.
    private var counts: [Counted] = []

    /// Creates the archive.
    ///
    /// - Parameters:
    ///   - calendar: the calendar to use, read on every write. The default is
    ///     the autoupdating calendar; a test passes a fixed one, or a closure
    ///     over one it changes.
    ///   - now: the clock, for a caller or a test that has one of its own.
    ///   - home: the home directory the default folder is built under.
    ///   - beforeCommit: a hook for tests, run after a day file's replacement has
    ///     been written and flushed and immediately before it is renamed.
    public init(
        calendar: @escaping @Sendable () -> Calendar = { Calendar.autoupdatingCurrent },
        now: @escaping @Sendable () -> Date = { Date() },
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        beforeCommit: (@Sendable (URL) -> Void)? = nil
    ) {
        self.currentCalendar = calendar
        self.now = now
        self.home = home
        self.beforeCommit = beforeCommit
    }

    /// Adds one delivered take to the file of its local day.
    ///
    /// The section is appended, so a take archived twice - which a retried
    /// delivery could do - is two sections rather than a corrupted one. A
    /// rewrite of either finds the newest section holding those words.
    ///
    /// - Parameters:
    ///   - text: the transcript as it was delivered.
    ///   - date: when it was delivered, in the archive's calendar.
    ///   - folder: the folder to write into.
    /// - Throws: ``SecureFileError`` when the folder is missing or the file
    ///   cannot be replaced, and ``TranscriptArchiveError/unreadableDay(_:)``
    ///   when the day file is there but cannot be read.
    public func recordTake(_ text: String, at date: Date, folder: URL) throws {
        let calendar = currentCalendar()
        let file = try dayFile(for: date, in: folder, calendar: calendar)
        let stamp = anchor(for: date, calendar: calendar)
        let section = Section(
            anchorLine: Self.anchorLine(stamp),
            anchor: stamp,
            body: Self.body(time: clock(for: date, calendar: calendar), text: text, versions: [])
        )
        let header = header(for: date, calendar: calendar)
        try update(file) { current in
            // A take reaches here twice when two changes race, because a rewrite
            // that overtook its take has already written this section with its
            // versions. Appending a second section for one delivery would leave
            // two sections claiming one instant, and every later rewrite of
            // those words would be refused as ambiguous.
            guard !Self.holdsTake(at: date, text: text, in: current) else { return nil }
            return (Self.appending(section, to: current, header: header), stamp)
        }
        rememberTake(text, at: date, in: file)
    }

    /// Replaces the rewrites listed under one take.
    ///
    /// The list is regenerated whole on every call, which is what makes a
    /// repeated call idempotent: the same versions produce the same bytes. The
    /// take is found by the section this process wrote for it, then by the
    /// newest section in the day files for its instant and the two days either
    /// side of it, and only then is a new section appended - which is how a
    /// rewrite made after a restart, or after the time zone changed, still lands
    /// under the words it rewrote.
    ///
    /// A snapshot carrying fewer versions than the one already written for that
    /// take is dropped. Two card changes can reach here out of order, and the
    /// shorter list is the older one.
    ///
    /// - Parameters:
    ///   - original: the take the versions were made from.
    ///   - date: when the take was delivered, in the archive's calendar.
    ///   - versions: the completed rewrites, in the order they were asked for.
    ///   - folder: the folder to write into.
    /// - Throws: ``SecureFileError`` when the folder is missing or the file
    ///   cannot be replaced, ``TranscriptArchiveError/unreadableDay(_:)`` when a
    ///   day file Dot would write is there but cannot be read, and
    ///   ``TranscriptArchiveError/concurrentWrite(_:)`` when the file changed
    ///   twice while it was being rebuilt.
    public func recordVersions(
        of original: String,
        takenAt date: Date,
        versions: [RewriteVersion],
        folder: URL
    ) throws {
        let calendar = currentCalendar()
        let text = Self.comparable(original)
        let blocks = Self.versionBlocks(versions)

        // The section this process wrote, found by instant rather than by the
        // anchor text, which is spelled differently in another time zone.
        if let known = written.first(where: { $0.text == text && Self.sameInstant($0.instant, date) }) {
            if refuses(versions, at: known.file, instant: known.instant) { return }
            let changed = try update(known.file) { current in
                try Self.change(
                    versionsOfTakeAt: date,
                    text: text,
                    in: current,
                    writing: blocks,
                    at: known.file
                )
            }
            if changed != nil {
                remember(versions.count, at: known.file, instant: date)
                return
            }
        }

        // The take's own day and the two either side of it, because the day a
        // take was filed under was named in the zone in force at the time.
        let target = try dayFile(for: date, in: folder, calendar: calendar)
        for candidate in Self.neighbourhood(of: date, in: folder, calendar: calendar) {
            if candidate != target {
                // A neighbour is only searched. Nothing is written to it unless
                // it holds the take, so a file Dot cannot read is passed over
                // instead of blocking a rewrite of another day.
                guard let content = Self.search(candidate) else { continue }
                switch Self.rewriting(versionsOfTakeAt: date, text: text, in: content, with: blocks) {
                case .none:
                    continue
                case .ambiguous:
                    throw TranscriptArchiveError.ambiguous(candidate.path)
                case .section:
                    break
                }
            }
            if refuses(versions, at: candidate, instant: date) { return }
            let changed = try update(candidate) { current in
                try Self.change(
                    versionsOfTakeAt: date,
                    text: text,
                    in: current,
                    writing: blocks,
                    at: candidate
                )
            }
            if changed != nil {
                remember(versions.count, at: candidate, instant: date)
                return
            }
        }

        // Words the files do not hold: the take is written now, with its
        // versions, under the anchor of the moment it was delivered.
        let stamp = anchor(for: date, calendar: calendar)
        let header = header(for: date, calendar: calendar)
        let section = Section(
            anchorLine: Self.anchorLine(stamp),
            anchor: stamp,
            body: Self.body(time: clock(for: date, calendar: calendar), text: original, versions: versions)
        )
        let changed = try update(target) { current in
            (Self.appending(section, to: current, header: header), stamp)
        }
        if changed != nil {
            remember(versions.count, at: target, instant: date)
        }
    }

    /// Whether a file already holds this take: the same words at the same
    /// instant.
    private static func holdsTake(at instant: Date, text: String, in content: String) -> Bool {
        let wanted = comparable(text)
        return parse(content).sections.contains { section in
            guard let found = Self.instant(of: section.anchor) else { return false }
            return sameInstant(found, instant) && takeText(of: section.body) == wanted
        }
    }

    private func rememberTake(_ text: String, at instant: Date, in file: URL) {
        let key = Self.comparable(text)
        written.removeAll { $0.text == key && Self.sameInstant($0.instant, instant) }
        written.append(Written(file: file, instant: instant, text: key))
    }

    /// Whether this snapshot is older than the one already written.
    private func refuses(_ versions: [RewriteVersion], at file: URL, instant: Date) -> Bool {
        guard let last = counts.first(where: {
            $0.file == file && Self.sameInstant($0.instant, instant)
        })?.count else { return false }
        return versions.count < last
    }

    private func remember(_ count: Int, at file: URL, instant: Date) {
        let index = counts.firstIndex { $0.file == file && Self.sameInstant($0.instant, instant) }
        if let index {
            counts[index] = Counted(file: file, instant: counts[index].instant, count: count)
        } else {
            counts.append(Counted(file: file, instant: instant, count: count))
        }
    }
}

// MARK: - The day file

extension TranscriptArchive {
    /// The file one delivery belongs in, with its folder prepared.
    ///
    /// The default folder is Dot's own, so Dot may create it. A folder the
    /// person chose is theirs: a missing one is an error the Settings row can
    /// report, never a directory invented on their behalf.
    private func dayFile(for date: Date, in folder: URL, calendar: Calendar) throws -> URL {
        if Self.isDefaultFolder(folder, home: home) {
            try SecureFile.createDirectory(at: folder)
        } else {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw SecureFileError.cannotCreate(folder.path)
            }
        }
        return folder.appendingPathComponent("\(Self.dayName(for: date, calendar: calendar)).md")
    }

    private static func isDefaultFolder(_ folder: URL, home: URL) -> Bool {
        folder.standardizedFileURL == TranscriptArchiveFolder.defaultURL(home: home).standardizedFileURL
    }

    /// The day files a take could be in: the day of its instant, and two days
    /// either side, as the current zone names them.
    ///
    /// Two, not one, because the zones a person can be in span twenty six hours:
    /// the same instant is two calendar days apart at UTC+14 and UTC-11.
    private static func neighbourhood(of date: Date, in folder: URL, calendar: Calendar) -> [URL] {
        var names: [String] = []
        for offset in [0, -1, 1, -2, 2] {
            guard let moment = calendar.date(byAdding: .day, value: offset, to: date) else { continue }
            let name = dayName(for: moment, calendar: calendar)
            guard !names.contains(name) else { continue }
            names.append(name)
        }
        return names.map { folder.appendingPathComponent("\($0).md") }
    }

    /// Applies one change to a day file, with the person's own edits protected.
    ///
    /// The change is a function from the file's current text to its new text and
    /// the anchor it changed, or `nil` when there is nothing to do.
    ///
    /// A whole file is replaced, so a change made underneath Dot would be lost.
    /// The file is stamped when it is read, and the stamp is compared again at
    /// the commit boundary: after the replacement has been written and flushed
    /// but before the rename, which is the last moment a check can still stop
    /// the write. If the stamp moved, the change is re-read and re-applied once
    /// against what is now there.
    ///
    /// The check is not an atomic compare-and-swap. It sees an edit made before
    /// the commit and cannot see one made in the instant between the check and
    /// the rename, which would have to be a writer changing the file inside that
    /// one syscall.
    ///
    /// - Returns: the anchor of the take that was changed, or `nil` when the
    ///   change had nothing to do.
    @discardableResult
    private func update(_ file: URL, _ change: Change) throws -> String? {
        var attempts = 0
        while true {
            let before = Self.stamp(of: file)
            let current = try Self.read(file)
            guard let changed = try change(current) else { return nil }
            do {
                try Self.write(changed.content, to: file) {
                    beforeCommit?(file)
                    guard Self.stamp(of: file) == before else { throw CommitRace() }
                }
                return changed.anchor
            } catch is CommitRace {
                attempts += 1
                guard attempts < 2 else {
                    throw TranscriptArchiveError.concurrentWrite(file.path)
                }
            }
        }
    }

    /// The day file's text, or an empty day when the file is not there.
    ///
    /// Only a file that does not exist may start an empty day. A read that fails
    /// any other way - bytes that are not text, a folder this account cannot
    /// read, a disk that answered with an error - throws, because the next step
    /// replaces the file whole and the words in it were never seen.
    private static func read(_ file: URL) throws -> String {
        do {
            return try String(contentsOf: file, encoding: .utf8)
        } catch let error as NSError where Self.isMissing(error) {
            return ""
        } catch {
            throw TranscriptArchiveError.unreadableDay(file.path)
        }
    }

    /// A day file being looked in, or `nil` when it cannot be read.
    ///
    /// Only a file Dot would not write is searched this way: passing over one it
    /// cannot read risks a duplicate section, never a lost word.
    private static func search(_ file: URL) -> String? {
        try? read(file)
    }

    private static func isMissing(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) {
            return true
        }
        return false
    }

    /// The file's size and date, or `nil` when it is not there.
    private static func stamp(of file: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else {
            return nil
        }
        return Stamp(
            size: (attributes[.size] as? NSNumber)?.intValue ?? -1,
            modified: attributes[.modificationDate] as? Date
        )
    }

    private static func write(
        _ content: String,
        to file: URL,
        beforeCommit: () throws -> Void = {}
    ) throws {
        try SecureFile.replace(
            Data(content.utf8),
            inExistingFolder: file,
            beforeCommit: beforeCommit
        )
    }
}

// MARK: - Stamps

extension TranscriptArchive {
    /// The title a new day file starts with, e.g. `16 November 2026`.
    private func header(for date: Date, calendar: Calendar) -> [String] {
        ["# \(Self.format(date, "d MMMM yyyy", calendar: calendar))", ""]
    }

    /// The heading time, e.g. `14:32:05`.
    private func clock(for date: Date, calendar: Calendar) -> String {
        Self.format(date, "HH:mm:ss", calendar: calendar)
    }

    /// The day file's name, e.g. `2026-11-16`.
    private static func dayName(for date: Date, calendar: Calendar) -> String {
        format(date, "yyyy-MM-dd", calendar: calendar)
    }

    private static func format(_ date: Date, _ pattern: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// The HTML comment marker a take carries, with the full timestamp.
    ///
    /// The offset is the one the calendar's zone had at that instant, so the
    /// anchor names the instant even after the person changes zone.
    private func anchor(for date: Date, calendar: Calendar) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: date)
    }

    private static func anchorLine(_ anchor: String) -> String {
        "<!-- dot-take \(anchor) -->"
    }

    /// The anchor a line carries, when the line is one.
    private static func anchor(of line: String) -> String? {
        let prefix = "<!-- dot-take "
        let suffix = " -->"
        guard line.hasPrefix(prefix), line.hasSuffix(suffix) else { return nil }
        let stamp = line.dropFirst(prefix.count).dropLast(suffix.count)
        guard !stamp.isEmpty, !stamp.contains(where: \.isWhitespace) else { return nil }
        return String(stamp)
    }

    /// The instant an anchor names.
    ///
    /// The offset is part of the anchor, so this reads the same instant in any
    /// zone.
    private static func instant(of anchor: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: anchor)
    }

    /// Whether two stamps name the same moment, to the precision an anchor
    /// carries.
    private static func sameInstant(_ one: Date, _ other: Date) -> Bool {
        abs(one.timeIntervalSince(other)) <= 0.001
    }
}

// MARK: - The file's shape

extension TranscriptArchive {
    /// One take, as it sits in the file.
    private struct Section {
        let anchorLine: String
        let anchor: String
        var body: [String]
    }

    /// A whole day file, with everything the owner wrote kept where it was.
    private struct DayFile {
        var header: [String]
        var sections: [Section]
    }

    /// The lines of a section body: the heading, the take, then one block per
    /// version.
    private static func body(time: String, text: String, versions: [RewriteVersion]) -> [String] {
        var lines = ["## \(time)", ""]
        lines.append(contentsOf: escapedLines(text))
        for block in versionBlocks(versions) {
            lines.append("")
            lines.append(contentsOf: block)
        }
        return lines
    }

    /// One version as the lines it occupies: its heading, a blank line and its
    /// words.
    private static func versionBlocks(_ versions: [RewriteVersion]) -> [[String]] {
        versions.map { version in
            ["### \(version.label)", ""] + escapedLines(version.text)
        }
    }

    /// The file with one more section at the end.
    ///
    /// The section before it is closed with exactly one blank line, which is
    /// the separator the format promises whatever the person left at the end.
    private static func appending(_ section: Section, to content: String, header: [String]) -> String {
        var file = parse(content)
        if let last = file.sections.indices.last {
            file.sections[last].body = closed(file.sections[last].body)
        }
        if file.sections.isEmpty, file.header.isEmpty {
            file.header = header
        }
        file.sections.append(section)
        return serialize(file)
    }

    /// What one file has to say about a take.
    private enum Resolution {
        /// The file does not hold the take.
        case none
        /// One section is the take.
        case section(content: String, anchor: String)
        /// Two sections carry the instant and the words do not choose between
        /// them.
        case ambiguous
    }

    /// The file with the version list of the section holding one instant
    /// regenerated.
    ///
    /// Two takes can only share an instant if they were delivered within the
    /// same millisecond. When that happens the words decide, and when the words
    /// are the same too there is no right answer: the version is refused rather
    /// than attached to a take the person did not mean.
    private static func rewriting(
        versionsOfTakeAt instant: Date,
        text: String,
        in content: String,
        with blocks: [[String]]
    ) -> Resolution {
        var file = parse(content)
        let matching = file.sections.indices.filter { index in
            guard let found = Self.instant(of: file.sections[index].anchor) else { return false }
            return sameInstant(found, instant)
        }
        guard matching.count != 1 else {
            let index = matching[0]
            file.sections[index].body = rewritingVersions(in: file.sections[index].body, with: blocks)
            return .section(content: serialize(file), anchor: file.sections[index].anchor)
        }
        guard matching.count > 1 else { return .none }
        let byText = matching.filter { takeText(of: file.sections[$0].body) == text }
        guard byText.count == 1 else { return .ambiguous }
        let index = byText[0]
        file.sections[index].body = rewritingVersions(in: file.sections[index].body, with: blocks)
        return .section(content: serialize(file), anchor: file.sections[index].anchor)
    }

    /// The change that lists `versions` under one take, or `nil` when the file
    /// does not hold it.
    private static func change(
        versionsOfTakeAt instant: Date,
        text: String,
        in content: String,
        writing blocks: [[String]],
        at file: URL
    ) throws -> (content: String, anchor: String)? {
        switch rewriting(versionsOfTakeAt: instant, text: text, in: content, with: blocks) {
        case .none:
            return nil
        case .ambiguous:
            throw TranscriptArchiveError.ambiguous(file.path)
        case .section(let content, let anchor):
            return (content, anchor)
        }
    }

    /// A section body with its version blocks replaced and its separator kept.
    ///
    /// The version list begins at the first `### ` heading. A line inside a take
    /// or a version that looks like one is written with a leading backslash, so
    /// an unescaped heading can only be one of ours.
    private static func rewritingVersions(in body: [String], with blocks: [[String]]) -> [String] {
        let (content, separator) = splitTrailingBlanks(body)
        let start = content.firstIndex { $0.hasPrefix("### ") } ?? content.endIndex
        var lines = Array(content[..<start])
        // The blank line above the first heading separates the take from its
        // versions, so it belongs to the region being regenerated. Leaving it
        // would add one blank line per write.
        if lines.last?.isEmpty == true { lines.removeLast() }
        for block in blocks {
            lines.append("")
            lines.append(contentsOf: block)
        }
        return lines + separator
    }

    /// The words a section holds, read back through the escaping.
    ///
    /// The version list is not part of the words: without stopping at the first
    /// `### ` heading, a take that already carries a version would never match
    /// the text it was written from, and the next rewrite would append a second
    /// copy of the same take.
    private static func takeText(of body: [String]) -> String {
        var lines = splitTrailingBlanks(body).content
        if lines.first?.hasPrefix("## ") == true { lines.removeFirst() }
        if lines.first?.isEmpty == true { lines.removeFirst() }
        if let heading = lines.firstIndex(where: { $0.hasPrefix("### ") }) {
            lines = Array(lines[..<heading])
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return comparable(lines.map(unescaping).joined(separator: "\n"))
    }

    private static func parse(_ content: String) -> DayFile {
        var header: [String] = []
        var sections: [Section] = []
        for line in lines(in: content) {
            guard let anchor = anchor(of: line) else {
                if sections.isEmpty {
                    header.append(line)
                } else {
                    sections[sections.count - 1].body.append(line)
                }
                continue
            }
            sections.append(Section(anchorLine: line, anchor: anchor, body: []))
        }
        return DayFile(header: header, sections: sections)
    }

    private static func serialize(_ file: DayFile) -> String {
        var lines = file.header
        for section in file.sections {
            lines.append(section.anchorLine)
            lines.append(contentsOf: section.body)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Lines and escaping

extension TranscriptArchive {
    private static func lines(in content: String) -> [String] {
        var result: [String] = []
        var index = content.startIndex
        while index < content.endIndex {
            let start = index
            var cursor = index
            while cursor < content.endIndex, content[cursor] != "\n" {
                cursor = content.index(after: cursor)
            }
            result.append(String(content[start..<cursor]))
            index = cursor < content.endIndex ? content.index(after: cursor) : cursor
        }
        return result
    }

    /// A body closed with exactly one blank line, which is how sections are
    /// separated.
    private static func closed(_ body: [String]) -> [String] {
        splitTrailingBlanks(body).content + [""]
    }

    /// A body split into what it says and the blank lines that follow it.
    private static func splitTrailingBlanks(_ body: [String]) -> (content: [String], separator: [String]) {
        var end = body.count
        while end > 0, body[end - 1].isEmpty {
            end -= 1
        }
        return (Array(body[0..<end]), Array(body[end...]))
    }

    private static func escapedLines(_ text: String) -> [String] {
        let trimmed = trimmingTrailingNewlines(text)
        guard !trimmed.isEmpty else { return [] }
        return trimmed.components(separatedBy: "\n").map(escaping)
    }

    /// A line that could be mistaken for the file's own structure is marked.
    ///
    /// Three shapes are ambiguous at the start of a line: a `#` heading, the
    /// `<!-- dot-take ... -->` anchor, and a backslash, because a backslash is
    /// what marks the other two. Prefixing one more backslash keeps the words
    /// exactly as they were said while leaving the structure unambiguous, and
    /// ``unescaping(_:)`` takes it off again.
    private static func escaping(_ line: String) -> String {
        if line.hasPrefix("\\") { return "\\" + line }
        if line.hasPrefix("<!--") { return "\\" + line }
        if line.first(where: { !$0.isWhitespace }) == "#" { return "\\" + line }
        return line
    }

    private static func unescaping(_ line: String) -> String {
        guard line.hasPrefix("\\") else { return line }
        let rest = line.dropFirst()
        if rest.hasPrefix("\\") || rest.hasPrefix("<!--") { return String(rest) }
        if rest.first(where: { !$0.isWhitespace }) == "#" { return String(rest) }
        return line
    }

    /// The form two copies of the same take are compared in.
    private static func comparable(_ text: String) -> String {
        trimmingTrailingNewlines(text)
    }

    private static func trimmingTrailingNewlines(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard text[previous] == "\n" || text[previous] == "\r" else { break }
            end = previous
        }
        return String(text[text.startIndex..<end])
    }
}
