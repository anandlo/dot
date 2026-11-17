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

        /// The reason, said without repeating the address that produced it.
        ///
        /// A typed address can carry a query string, and a proxy URL can carry a
        /// credential in it. A sentence shown on a page or a card is not a place
        /// to copy that text back: the three fixed lines name what to change
        /// instead, which is the only part the person needs.
        public var safeDescription: String {
            switch self {
            case .notAnAddress:
                "That is not an address Dot can reach. Use https, or 127.0.0.1 for a server on this Mac."
            case .unsupportedScheme:
                "Dot speaks https, or http for a server on this Mac."
            case .cleartextHost:
                "That address would be reached unencrypted. Use https, "
                    + "or 127.0.0.1 for a server on this Mac."
            }
        }
    }

    /// Whether a host names the machine Dot runs on.
    ///
    /// A host name is text a service or a proxy can choose, so only three
    /// literal spellings count: `localhost`, the IPv6 loopback, and a dotted
    /// decimal address in `127.0.0.0/8`. A name that merely starts with `127.`
    /// is not one — `127.example.com` and `127.0.0.1.nip.io` resolve wherever
    /// their owner says, and treating them as this Mac would send a key in
    /// clear text to a stranger.
    ///
    /// - Parameter host: the host of a URL, without a scheme or a port.
    /// - Returns: `true` for `localhost`, every numeric address in
    ///   `127.0.0.0/8` and the IPv6 loopback.
    public static func isLoopback(_ host: String) -> Bool {
        let name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bare = name.hasPrefix("[") && name.hasSuffix("]") ? String(name.dropFirst().dropLast()) : name
        if bare == "localhost" || bare == "::1" { return true }
        return isNumericLoopbackIPv4(bare)
    }

    /// Whether a host is a dotted decimal address in `127.0.0.0/8`.
    ///
    /// Four decimal octets, each 0...255, with no leading zero on a longer
    /// octet: an octet with a leading zero is read as octal by some resolvers
    /// and decimal by others, so the spelling that would mean two addresses is
    /// not accepted as either.
    ///
    /// - Parameter host: a lowercased host without brackets.
    /// - Returns: whether the four octets are a loopback address.
    static func isNumericLoopbackIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "127" else { return false }
        for octet in octets {
            guard (1 ... 3).contains(octet.count),
                  octet.allSatisfy({ character in character >= "0" && character <= "9" }),
                  octet.count == 1 || octet.first != "0",
                  let value = Int(octet),
                  (0 ... 255).contains(value)
            else { return false }
        }
        return true
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
