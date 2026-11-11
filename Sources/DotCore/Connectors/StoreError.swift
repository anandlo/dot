import Foundation

/// A failure a connector store reports, in words a person can read.
///
/// Stores do not throw their framework's errors at the model: an EventKit
/// `EKError` and a `CNError` mean nothing to a language model, and a raw
/// `NSError` can carry a path or a contact name. Every adapter translates to
/// this one type, whose message is safe to put in a tool result.
public struct StoreError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The sentence the model reads.
    public let message: String

    /// Creates an error.
    ///
    /// - Parameter message: what went wrong, in one sentence.
    public init(_ message: String) {
        self.message = message
    }

    /// The sentence, for interpolation.
    public var description: String { message }
}
