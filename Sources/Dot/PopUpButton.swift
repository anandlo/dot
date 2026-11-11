import AppKit
import SwiftUI

@MainActor
struct PopUpButton<Value: Hashable>: NSViewRepresentable {
    let options: [DotSelectOption<Value>]
    @Binding var selection: Value?
    let placeholder: String
    let width: CGFloat
    let isEnabled: Bool

    @MainActor
    final class Coordinator {
        var parent: PopUpButton

        init(_ parent: PopUpButton) {
            self.parent = parent
        }

        @objc func changed(_ sender: NSPopUpButton) {
            guard let item = sender.selectedItem, item.tag >= 0 else { return }
            guard parent.options.indices.contains(item.tag) else { return }
            parent.selection = parent.options[item.tag].value
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> PopUpContainer {
        let container = PopUpContainer()
        let button = container.button
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        container.fixedWidth = width
        return container
    }

    func updateNSView(_ container: PopUpContainer, context: Context) {
        context.coordinator.parent = self
        container.fixedWidth = width
        container.invalidateIntrinsicContentSize()
        let button = container.button
        button.isEnabled = isEnabled

        let menu = NSMenu()
        menu.autoenablesItems = false
        let selectedIndex = options.firstIndex { $0.value == selection }
        let hasPlaceholder = selectedIndex == nil
        if hasPlaceholder {
            let item = NSMenuItem(title: placeholder, action: nil, keyEquivalent: "")
            item.tag = -1
            item.isEnabled = false
            menu.addItem(item)
        }
        for (index, option) in options.enumerated() {
            let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            item.tag = index
            if let detail = option.detail, #available(macOS 14.4, *) {
                item.subtitle = detail
            }
            menu.addItem(item)
        }
        button.menu = menu
        let offset = hasPlaceholder ? 1 : 0
        button.selectItem(at: (selectedIndex ?? -1) + offset)
        button.setAccessibilityValue(button.titleOfSelectedItem ?? placeholder)
    }
}

/// Holds an `NSPopUpButton` at a size Dot decides.
///
/// `NSPopUpButton` grows to the width of its longest menu item as soon as a menu
/// is attached, which made two pickers in one card two different widths. The
/// container pins the button to its own width, and the width is the one the
/// row asked for.
final class PopUpContainer: NSView {
    let button = NSPopUpButton(frame: .zero, pullsDown: false)
    var fixedWidth: CGFloat = 220

    init() {
        super.init(frame: .zero)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.controlSize = .regular
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 13)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: fixedWidth, height: button.intrinsicContentSize.height)
    }
}
