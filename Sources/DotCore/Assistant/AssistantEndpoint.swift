import Foundation

/// Joins a chat service's base address and a relative path.
///
/// A base URL and a path are written by different people: a vendor documents
/// `https://api.anthropic.com`, a person types `https://api.anthropic.com/v1`,
/// and the catalogue's path already begins with `v1`. Appending the path as it
/// stands would ask the second form for `/v1/v1/messages`, which the service
/// does not serve. The first segment is therefore dropped when the base URL
/// already ends with it, and the rest of the path is appended as written.
public enum AssistantEndpoint {
    /// The address a request is posted to.
    ///
    /// - Parameters:
    ///   - base: the base URL, with or without a trailing slash.
    ///   - path: the path relative to it, with or without a leading slash.
    /// - Returns: the joined address, with no repeated version segment.
    public static func url(base: URL, path: String) -> URL {
        var segments = path.split(separator: "/").map(String.init)
        guard !segments.isEmpty else { return base }
        let baseSegments = base.path.split(separator: "/").map(String.init)
        if let first = segments.first, baseSegments.last == first {
            segments.removeFirst()
        }
        return segments.reduce(base) { url, segment in
            url.appendingPathComponent(segment)
        }
    }
}
