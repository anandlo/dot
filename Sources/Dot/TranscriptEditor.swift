import AppKit
import SwiftUI

/// The transcript, in a field that can be corrected.
///
/// The island is a glance: it cannot hold a cursor, because it never becomes the
/// key window and it dismisses itself. Editing is a different job, so it gets a
/// window of its own, with the same paper, the same type and the same controls
/// as the rest of the app instead of a system text sheet.
@MainActor
struct TranscriptEditorView: View {
    /// The text being corrected.
    @ObservedObject var draft: TranscriptDraft
    /// Copies what the field holds.
    let onCopy: () -> Void
    /// Pastes it again.
    let onPaste: () -> Void
    /// Keeps the correction and closes.
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            editor
            footer
        }
        .frame(width: 560, height: 380)
        .background(DotPaper())
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.cursor")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DotTheme.accent)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DotTheme.accentSoft)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("Transcript")
                    .font(DotTheme.sectionFont)
                    .foregroundStyle(DotTheme.ink)
                Text("Correct it here. The paste shortcut uses what this field holds.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DotTheme.ink3)
            }
            Spacer(minLength: 8)
            Text("\(draft.text.count) characters")
                .font(.system(size: 10.5))
                .foregroundStyle(DotTheme.ink3)
        }
        .padding(.horizontal, 20)
        .padding(.top, 44)
        .padding(.bottom, 12)
    }

    private var editor: some View {
        TextEditor(text: $draft.text)
            .font(.system(size: 13))
            .foregroundStyle(DotTheme.ink)
            .scrollContentBackground(.hidden)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DotTheme.fieldFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(DotTheme.cardBorder, lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .frame(maxHeight: .infinity)
            .accessibilityLabel(Text("Transcript"))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Copy") { onCopy() }
                .buttonStyle(DotSecondaryButtonStyle())
                .accessibilityHint("Copies the text in this field.")
            Button("Paste again") { onPaste() }
                .buttonStyle(DotSecondaryButtonStyle())
                .accessibilityHint("Pastes the text in this field into the app that was in front.")
            Spacer(minLength: 12)
            Button("Done") { onDone() }
                .buttonStyle(DotPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Keeps the correction and closes this window.")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

/// The text the editor is correcting.
///
/// The view owns the field; the controller owns the draft, so the text survives
/// the window being closed and reopened and the caller can read it back when the
/// person is done.
@MainActor
final class TranscriptDraft: ObservableObject {
    /// What the field holds right now.
    @Published var text: String

    /// Creates a draft.
    ///
    /// - Parameter text: the transcript to correct.
    init(text: String = "") {
        self.text = text
    }
}

/// Owns the editor window.
@MainActor
final class TranscriptEditorWindowController {
    private var host: DotWindowHost?
    private let draft = TranscriptDraft()

    /// Shows the editor with a transcript in it.
    ///
    /// - Parameters:
    ///   - text: the transcript to correct.
    ///   - onCopy: copies the corrected text.
    ///   - onPaste: pastes the corrected text again.
    ///   - onCommit: receives the corrected text when the person is done.
    func show(
        text: String,
        onCopy: @escaping (String) -> Void,
        onPaste: @escaping (String) -> Void,
        onCommit: @escaping (String) -> Void
    ) {
        let draft = self.draft
        draft.text = text
        let host = existingHost()
        host.present {
            TranscriptEditorView(
                draft: draft,
                onCopy: { onCopy(draft.text) },
                onPaste: { onPaste(draft.text) },
                onDone: { [weak self] in
                    onCommit(draft.text)
                    self?.close()
                }
            )
        }
    }

    /// Closes the window.
    func close() {
        host?.dismiss()
    }

    private func existingHost() -> DotWindowHost {
        if let host {
            return host
        }
        let host = DotWindowHost(
            title: "Transcript",
            size: CGSize(width: 560, height: 380)
        )
        self.host = host
        return host
    }
}
