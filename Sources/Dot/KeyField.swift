import Combine
import Foundation

/// The text in the API key field.
///
/// The key field is the one control on the Speech to text page whose text a
/// pick has to throw away. The text lives in a reference the page, the field
/// and the check share, so the three cannot disagree: a pick empties it, the
/// field redraws empty, and the check the pick starts reads the same emptiness.
@MainActor
final class KeyField: ObservableObject {
    /// The text as it is typed, pasted or discarded.
    @Published var text: String

    /// Creates a field.
    ///
    /// - Parameter text: the text the field starts with.
    init(text: String = "") {
        self.text = text
    }
}
