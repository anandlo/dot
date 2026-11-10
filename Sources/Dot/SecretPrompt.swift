import AppKit
import DotCore

/// A small window that asks the user for a secret.
///
/// The secret is typed into a secure text field and is handed straight to the
/// Keychain: it is never written into the configuration file, never logged
/// and never put on a command line.
@MainActor
final class SecretPrompt {
    /// Called with the secret, or `nil` when the user cancelled.
    var completion: ((String?) -> Void)?

    private var window: NSWindow?
    private let field = NSSecureTextField()

    /// The title of the window.
    var title = "Set API Key"

    /// The line under the field that explains what the key is for.
    var explanation = ""

    /// Opens the window.
    func begin() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 148),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.center()

        let caption = NSTextField(labelWithString: title)
        caption.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        caption.textColor = NSColor.labelColor

        let hint = NSTextField(labelWithString: explanation)
        hint.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        hint.textColor = NSColor.secondaryLabelColor
        hint.alignment = .center
        hint.stringValue = explanation

        field.isEditable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.alignment = .left
        field.font = NSFont.systemFont(ofSize: 13)
        field.placeholderString = "Paste the key"

        let stack = NSStackView(views: [caption, hint, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            caption.heightAnchor.constraint(equalToConstant: 20),
            hint.heightAnchor.constraint(equalToConstant: 16),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])

        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
    }

    /// Closes the window.
    func cancel() {
        window?.close()
        window = nil
    }

    /// Reads the field and closes the window.
    func submit() {
        let secret = field.stringValue
        cancel()
        completion?(secret.isEmpty ? nil : secret)
    }
}
