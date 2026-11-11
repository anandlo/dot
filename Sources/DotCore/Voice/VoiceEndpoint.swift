import Foundation

/// The address rule every voice request goes through.
///
/// A voice base URL can be edited in a configuration file, and the request that
/// follows carries an API key and the text of an answer. Over cleartext both
/// travel on the network, so a remote host is only ever reached over TLS, and a
/// plain `http` address is allowed only for the machine Dot runs on. The rule
/// itself is ``EndpointPolicy``'s; this is the voice side of it, which turns a
/// rejection into the error the card shows.
public enum VoiceEndpoint {
    /// Checks an address and returns it.
    ///
    /// - Parameter url: the address a request is about to be sent to.
    /// - Returns: the same address, when it is accepted.
    /// - Throws: ``ProviderError/unavailable(_:)`` with the reason it is not.
    @discardableResult
    public static func validate(_ url: URL) throws -> URL {
        if let rejection = EndpointPolicy.validate(url) {
            throw ProviderError.unavailable(rejection.localizedDescription)
        }
        return url
    }

    /// Reads a stored address and checks it.
    ///
    /// - Parameters:
    ///   - string: the address as it was stored.
    ///   - fallback: the address to use when the stored one is empty.
    /// - Returns: a usable address.
    /// - Throws: ``ProviderError/unavailable(_:)`` with the reason it is not.
    public static func url(_ string: String?, fallback: URL) throws -> URL {
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return fallback }
        do {
            return try validate(EndpointPolicy.url(from: trimmed))
        } catch let rejection as EndpointPolicy.Rejection {
            throw ProviderError.unavailable(rejection.localizedDescription)
        }
    }
}
