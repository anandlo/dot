import Foundation

/// What an update check learns from one GitHub Releases response.
///
/// GitHub's `/releases/latest` answers with the newest release that is *not* a
/// prerelease. Every Dot release is one while the product is in beta, so that
/// endpoint answers `404` and the list endpoint — `/releases?per_page=1`,
/// newest first, prereleases included — is the one that can answer.
///
/// `scripts/install-remote.sh` already makes exactly this fallback over curl.
/// This type is the same decision in Swift, kept free of the network so each
/// status and body can be tested one at a time.
public enum ReleaseLookup {
    /// A release the check can compare with the running build.
    public struct Release: Equatable, Sendable {
        /// The tag with the leading `v` and any surrounding space removed,
        /// e.g. `1.2.3-beta`.
        public let version: String
        /// The release page, when the response named one.
        public let page: String?
        /// The release notes, when the response carried them.
        public let notes: String?

        public init(version: String, page: String? = nil, notes: String? = nil) {
            self.version = version
            self.page = page
            self.notes = notes
        }
    }

    /// Which endpoint answered.
    public enum Endpoint: Sendable {
        /// `repos/{owner}/{repo}/releases/latest`.
        case latest
        /// `repos/{owner}/{repo}/releases?per_page=1`.
        case list
    }

    /// Why a response did not name a release.
    public enum Reason: Equatable, Sendable {
        /// The endpoint answered with a status outside 200–299.
        case httpStatus(Int)
        /// The response carried no body.
        case emptyBody
        /// The body carried no tag to compare.
        case noTag
        /// The list endpoint answered with an empty array.
        case noRelease
    }

    /// What the check does next.
    public enum Decision: Equatable, Sendable {
        /// A release was named.
        case found(Release)
        /// The latest endpoint could not answer, so the list endpoint has to
        /// be asked.
        case askList(Reason)
        /// No endpoint can answer.
        case unavailable(Reason)
    }

    /// Decides what one response means.
    ///
    /// - Parameters:
    ///   - endpoint: which endpoint answered.
    ///   - status: the HTTP status it answered with.
    ///   - body: the bytes it answered with.
    /// - Returns: the release the response named, or why the check has to
    ///   ask somewhere else.
    public static func decide(_ endpoint: Endpoint, status: Int, body: Data) -> Decision {
        switch answer(in: body, endpoint: endpoint, status: status) {
        case .release(let release):
            return .found(release)
        case .reason(let reason):
            // Only the latest endpoint has somewhere else to go: asking the
            // list endpoint after the list endpoint is a loop.
            switch endpoint {
            case .latest: return .askList(reason)
            case .list: return .unavailable(reason)
            }
        }
    }

    /// What one body says, before the endpoint decides what that means.
    private enum Answer {
        case release(Release)
        case reason(Reason)
    }

    private static func answer(
        in body: Data,
        endpoint: Endpoint,
        status: Int
    ) -> Answer {
        // A 404 from `/releases/latest` carries GitHub's own JSON body; the
        // status is the answer, not the body that came with it.
        guard (200..<300).contains(status) else { return .reason(.httpStatus(status)) }
        guard !isBlank(body) else { return .reason(.emptyBody) }

        switch endpoint {
        case .latest:
            guard let entry = try? JSONDecoder().decode(Entry.self, from: body) else {
                return .reason(.noTag)
            }
            return answer(from: entry)
        case .list:
            guard let entries = try? JSONDecoder().decode([Entry].self, from: body) else {
                return .reason(.noTag)
            }
            guard let entry = entries.first else { return .reason(.noRelease) }
            return answer(from: entry)
        }
    }

    private static func answer(from entry: Entry) -> Answer {
        let version = normalized(entry.tag)
        guard !version.isEmpty else { return .reason(.noTag) }
        return .release(Release(version: version, page: entry.page, notes: entry.notes))
    }

    /// The tag as a version: no surrounding space, no leading `v`.
    static func normalized(_ tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.drop(while: { $0 == "v" || $0 == "V" }))
    }

    private static func isBlank(_ body: Data) -> Bool {
        body.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
    }

    /// The fields of a release that the check reads. GitHub sends many more;
    /// they are ignored rather than modelled, so a field being added cannot
    /// break the decode.
    private struct Entry: Decodable {
        let tag: String
        let page: String?
        let notes: String?

        private enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case page = "html_url"
            case notes = "body"
        }
    }
}
