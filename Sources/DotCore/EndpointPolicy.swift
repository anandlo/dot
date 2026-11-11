import Foundation

/// What Dot accepts as the address of a speech service.
///
/// A base URL is typed by hand, and the request that follows carries the audio
/// and the API key. Over `http` both travel in clear text on the local network,
/// so a cloud endpoint is only ever reached over TLS. The one exception is the
/// machine Dot runs on: a local `whisper.cpp`, LM Studio or Ollama server has
/// no certificate and never leaves the Mac, which is exactly the
/// OpenAI-compatible case the app exists to serve.
public enum EndpointPolicy {
    /// The scheme every remote endpoint has to use.
    public static let secureScheme = "https"
    /// The scheme a loopback endpoint may use.
    public static let cleartextScheme = "http"

    /// Why an endpoint was refused.
    public enum Rejection: Error, Equatable, LocalizedError, Sendable {
        /// The string is not an address with a scheme and a host.
        case notAnAddress(String)
        /// The scheme is neither `https` nor `http`.
        case unsupportedScheme(String)
        /// The address is `http` and the host is not the local machine.
        case cleartextHost(String)

        public var errorDescription: String? {
            switch self {
            case .notAnAddress(let detail):
                "That is not an address Dot can reach: \(detail)"
            case .unsupportedScheme(let scheme):
                "Dot speaks https. The address uses \(scheme.isEmpty ? "no scheme" : scheme)."
            case .cleartextHost(let host):
                "\(host) would be reached over an unencrypted connection. Use https, "
                    + "or 127.0.0.1 for a server on this Mac."
            }
        }
    }

    /// Whether a host names the machine Dot runs on.
    ///
    /// - Parameter host: the host of a URL, without a scheme or a port.
    /// - Returns: `true` for `localhost`, every address in `127.0.0.0/8` and the
    ///   IPv6 loopback.
    public static func isLoopback(_ host: String) -> Bool {
        let name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bare = name.hasPrefix("[") && name.hasSuffix("]") ? String(name.dropFirst().dropLast()) : name
        if bare == "localhost" || bare == "::1" { return true }
        if bare.hasPrefix("127.") { return true }
        // `localhost` is the only name guaranteed to resolve to the loopback;
        // a name that merely ends in it is not vouched for.
        return false
    }

    /// Whether an address may be used, and why it may not.
    ///
    /// - Parameter url: the address that was typed or stored.
    /// - Returns: `nil` when the address is accepted, the reason otherwise.
    public static func validate(_ url: URL) -> Rejection? {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            return .notAnAddress(url.absoluteString)
        }
        // The scheme is answered first: a person who typed `ftp://` is told
        // about the scheme, not about the shape of the address.
        guard scheme == secureScheme || scheme == cleartextScheme else {
            return .unsupportedScheme(scheme)
        }
        guard let host = url.host, !host.isEmpty else {
            return .notAnAddress(url.absoluteString)
        }
        switch scheme {
        case secureScheme:
            return nil
        default:
            return isLoopback(host) ? nil : .cleartextHost(host)
        }
    }

    /// Whether an address is accepted.
    ///
    /// - Parameter url: the address to check.
    public static func isAccepted(_ url: URL) -> Bool {
        validate(url) == nil
    }

    /// Reads a typed address and checks it.
    ///
    /// - Parameter string: the address as it was typed or stored.
    /// - Returns: the address, when it is usable.
    /// - Throws: ``Rejection`` with the reason the address is refused.
    public static func url(from string: String) throws -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw Rejection.notAnAddress(trimmed)
        }
        if let rejection = validate(url) { throw rejection }
        return url
    }
}
