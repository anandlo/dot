import Foundation

/// Reads the newest Dot release from GitHub, prereleases included.
///
/// The feed asks `/releases/latest` first and, when that endpoint cannot name a
/// release, asks the list endpoint — newest first, prereleases included — and
/// takes its first entry. That is the same fallback `scripts/install-remote.sh`
/// makes with curl, and it is why this check can find a beta at all: GitHub's
/// latest endpoint leaves prereleases out, and every Dot release is one.
public struct ReleaseFeed: Sendable {
    /// How long one request may take. Two requests are made when the latest
    /// endpoint cannot answer, so a check can take twice this long.
    public static let timeout: TimeInterval = 8

    /// `/releases/latest`.
    private let latestURL: URL
    /// `/releases?per_page=1`.
    private let listURL: URL

    /// Creates a feed.
    ///
    /// - Parameters:
    ///   - latest: the latest-release endpoint.
    ///   - list: the list endpoint, read when the latest one cannot answer.
    public init(latest: URL, list: URL) {
        self.latestURL = latest
        self.listURL = list
    }

    /// The newest release.
    ///
    /// - Returns: the release the endpoints named.
    /// - Throws: ``ReleaseFeedError`` when neither endpoint can name one, and
    ///   `URLError` when a request never reached the server.
    public func newest() async throws -> ReleaseLookup.Release {
        let latest = try await answer(from: latestURL)
        switch ReleaseLookup.decide(.latest, status: latest.status, body: latest.body) {
        case .found(let release):
            return release
        case .unavailable(let reason):
            throw ReleaseFeedError(reason: reason)
        case .askList(let reason):
            Log.shared.info("update.lookup.fallback", [
                "reason": .string(ReleaseFeedError.describe(reason)),
                "status": .int(latest.status),
            ])
            let list = try await answer(from: listURL)
            switch ReleaseLookup.decide(.list, status: list.status, body: list.body) {
            case .found(let release):
                return release
            case .unavailable(let reason), .askList(let reason):
                throw ReleaseFeedError(reason: reason)
            }
        }
    }

    private func answer(from url: URL) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("Dot-App-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = Self.timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (http.statusCode, data)
    }
}

/// Why the update check could not read a release.
public struct ReleaseFeedError: Error, Equatable, Sendable, CustomStringConvertible {
    /// What the response could not do.
    public let reason: ReleaseLookup.Reason

    public init(reason: ReleaseLookup.Reason) {
        self.reason = reason
    }

    public var description: String {
        Self.describe(reason)
    }

    /// One line about a reason, for the log.
    static func describe(_ reason: ReleaseLookup.Reason) -> String {
        switch reason {
        case .httpStatus(let status): return "the server answered \(status)"
        case .emptyBody: return "the response was empty"
        case .noTag: return "the response named no release"
        case .noRelease: return "no release has been published"
        }
    }
}
