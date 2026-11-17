import Foundation

/// What the archive does with one card's versions.
///
/// A card holds completed rewrites that only it can describe: the words they
/// were made from, the instant those words were delivered, and the versions
/// themselves. This is the one place that turns that into either a write or a
/// logged refusal, so the app never has to decide and a test can see both
/// without an `AppDelegate`.
public enum RewriteArchiveRequest {
    /// The reason a card with versions has nothing to file under.
    public static let noInstantReason = "no_instant"

    /// Files the card's versions, or records why there is nothing to file.
    ///
    /// A card can hold completed versions and no instant: an entry the history
    /// decoded without `addedAt`, restored and then rewritten, has no delivery
    /// to file the rewrite under. Writing it under today's date would put words
    /// in a day they were not said, so nothing is written and one line is
    /// logged instead. The line names the reason and nothing else: no words, no
    /// path, nothing the person dictated.
    ///
    /// Nothing is logged when the archive is switched off, because then nothing
    /// was skipped: the archive does not run at all.
    ///
    /// - Parameters:
    ///   - card: the card whose versions are being kept.
    ///   - enabled: whether the archive is switched on.
    ///   - write: what to do with a record that can be filed.
    ///   - log: the log the refusal goes to.
    public static func file(
        _ card: RewriteCard,
        enabled: Bool,
        with write: (RewriteArchiveRecord) -> Void,
        log: Log = .shared
    ) {
        guard enabled else { return }
        if let record = card.archiveRecord {
            write(record)
            return
        }
        guard card.versions.contains(where: { !$0.isOriginal }) else { return }
        log.info("archive.write.skipped", ["reason": .string(noInstantReason)])
    }
}
