import DotCore
import Foundation

/// Finds files with Spotlight, in process.
///
/// `NSMetadataQuery` needs a run loop, so the query is created, started and
/// observed on the main queue; the caller awaits a continuation and is resumed
/// with value types. A query that has not finished gathering after three
/// seconds is stopped and whatever it found is returned: a voice question about
/// a file cannot wait for a full index pass.
final class SpotlightFileSearch: FileSearching, @unchecked Sendable {
    /// The longest a query may take before its partial results are used.
    static let gatherTimeout: TimeInterval = 3

    func search(_ query: FileQuery) async throws -> [FileHit] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[FileHit], Error>) in
            DispatchQueue.main.async {
                let box = SpotlightQueryBox(continuation: continuation)
                box.start(query)
            }
        }
    }

    /// Builds the predicate from the query.
    ///
    /// The name clause is `CONTAINS`, not `LIKE`, so a `*` or `?` a person said
    /// is a character in a name rather than a wildcard that changes what the
    /// query means.
    static func predicate(for query: FileQuery) -> NSPredicate {
        var clauses: [NSPredicate] = [
            NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@", query.text),
        ]
        if let contentType = contentType(for: query.kind) {
            let key = query.kind == .image || query.kind == .audio || query.kind == .video
                ? "kMDItemContentTypeTree"
                : "kMDItemContentType"
            clauses.append(NSPredicate(format: "%K == %@", key, contentType))
        }
        if let days = query.modifiedWithinDays {
            let since = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
            clauses.append(NSPredicate(format: "kMDItemFSContentChangeDate >= %@", since as NSDate))
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: clauses)
    }

    /// The uniform type identifier a kind maps to.
    private static func contentType(for kind: FileQuery.Kind) -> String? {
        switch kind {
        case .any: nil
        case .folder: "public.folder"
        case .document: "public.text"
        case .image: "public.image"
        case .audio: "public.audio"
        case .video: "public.movie"
        case .presentation: "public.presentation"
        case .spreadsheet: "public.spreadsheet"
        }
    }

    /// Reads the query's results as value types.
    static func hits(_ query: NSMetadataQuery, limit: Int) -> [FileHit] {
        let items = query.results.compactMap { $0 as? NSMetadataItem }
        var seen: Set<String> = []
        var hits: [FileHit] = []
        for item in items {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            guard seen.insert(path).inserted else { continue }
            let url = URL(fileURLWithPath: path)
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            hits.append(FileHit(
                path: url.standardizedFileURL.path,
                name: (item.value(forAttribute: NSMetadataItemFSNameKey) as? String) ?? url.lastPathComponent,
                modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
                sizeBytes: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value,
                isFolder: isDirectory
            ))
            if hits.count >= limit { break }
        }
        return hits
    }
}

/// Holds one query and its observer, and resumes its continuation exactly once.
///
/// Everything in here runs on the main queue, which is what makes the unchecked
/// conformance sound: no field is read from another thread.
private final class SpotlightQueryBox: @unchecked Sendable {
    private let continuation: CheckedContinuation<[FileHit], Error>
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var finished = false

    init(continuation: CheckedContinuation<[FileHit], Error>) {
        self.continuation = continuation
    }

    func start(_ request: FileQuery) {
        let query = NSMetadataQuery()
        query.predicate = SpotlightFileSearch.predicate(for: request)
        query.searchScopes = [FileManager.default.homeDirectoryForCurrentUser]
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        self.query = query
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self] _ in
            self?.finish(limit: request.limit)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + SpotlightFileSearch.gatherTimeout) { [weak self] in
            self?.finish(limit: request.limit)
        }
        query.start()
    }

    private func finish(limit: Int) {
        guard !finished, let query else { return }
        finished = true
        query.disableUpdates()
        query.stop()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        continuation.resume(returning: SpotlightFileSearch.hits(query, limit: limit))
    }
}
