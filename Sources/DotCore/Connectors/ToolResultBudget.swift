import Foundation

/// Fits a tool's answer into the bytes the model may receive.
///
/// A file search, a shortcut listing or a calendar week can return more text
/// than the rest of the conversation put together. Sending all of it is slow,
/// expensive and pushes the instructions out of the model's attention, so every
/// result is cut to a fixed byte budget before it leaves the toolbox. The cut
/// lands on a character boundary and, when one is close, on a line boundary, so
/// the text never ends in half a character or half a line.
public struct ToolResultBudget: Sendable, Equatable {
    /// The shipped budget: eight kilobytes, about two thousand tokens.
    public static let defaultBytes = 8_000

    /// The budget this instance enforces.
    public let bytes: Int

    /// Creates a budget.
    ///
    /// - Parameter bytes: the maximum UTF-8 size of a result.
    public init(bytes: Int = ToolResultBudget.defaultBytes) {
        self.bytes = max(256, bytes)
    }

    /// Cuts `text` to the budget.
    ///
    /// - Parameter text: the tool's full answer.
    /// - Returns: the text to send, and whether anything was dropped.
    public func fit(_ text: String) -> FittedText {
        let original = text.utf8.count
        guard original > bytes else {
            return FittedText(text: text, wasTruncated: false, originalByteCount: original)
        }

        // Space is reserved for the note, so the note itself never pushes the
        // result past the budget.
        let note = "\n[truncated, \(original) bytes total]"
        let noteBytes = note.utf8.count
        let room = max(64, bytes - noteBytes)
        var kept = ""
        var keptBytes = 0
        var cutAtNewline: String?
        for character in text {
            let size = String(character).utf8.count
            if keptBytes + size > room { break }
            kept.append(character)
            keptBytes += size
            if character == "\n" { cutAtNewline = kept }
        }
        // A newline in the last half of the budget reads better than a word cut
        // in the middle; earlier than that, more text is worth more.
        if let cutAtNewline, cutAtNewline.utf8.count >= room / 2 {
            kept = cutAtNewline
        }
        return FittedText(
            text: kept + note,
            wasTruncated: true,
            originalByteCount: original
        )
    }
}

/// The result of fitting text to a budget.
public struct FittedText: Sendable, Equatable {
    /// What to send.
    public let text: String
    /// Whether anything was dropped.
    public let wasTruncated: Bool
    /// The size before the cut.
    public let originalByteCount: Int

    /// Creates a fitted value.
    public init(text: String, wasTruncated: Bool, originalByteCount: Int) {
        self.text = text
        self.wasTruncated = wasTruncated
        self.originalByteCount = originalByteCount
    }
}
