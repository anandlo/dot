import DotCore
import SwiftUI

/// The History window: the transcripts Dot remembers, on warm paper.
///
/// The view is only a surface. It receives the history newest first as the
/// transcripts themselves, reports a copy or a clear through its callbacks, and
/// closes through `onClose`. It never reads the history file, the clipboard or
/// the Keychain itself. It draws no timestamps: the store keeps when each entry
/// was added, and the palette is the surface that shows an age, because this
/// window is handed the words alone.
@MainActor
struct HistoryView: View {
    /// The transcripts, newest first. The order is kept as it arrives.
    let history: [String]
    /// Copies one transcript.
    let onCopy: (String) -> Void
    /// Asks to remove every transcript. The caller owns the confirmation.
    let onClear: () -> Void
    /// Closes the window.
    let onClose: () -> Void
    /// The recording shortcut, so an instruction names the one the user set.
    var recordHotkey: Hotkey = .defaultRecord

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.historyHeadless) private var headless

    @State private var query: String
    @State private var appeared = false
    @State private var copiedID: Int?
    @State private var copyToken = 0
    @FocusState private var searchFocused: Bool
    @FocusState private var searchClearFocused: Bool
    @FocusState private var clearFocused: Bool
    @State private var focusRequest = 0
    @State private var tabTarget = 0

    /// Creates the view.
    ///
    /// - Parameters:
    ///   - history: The transcripts, newest first.
    ///   - onCopy: Copies one transcript.
    ///   - onClear: Asks to remove the whole history.
    ///   - onClose: Closes the window.
    ///   - initialQuery: A starting search for the headless renderer. The real
    ///     window always starts with an empty field.
    ///   - recordHotkey: The recording shortcut the app is running with.
    init(
        history: [String],
        onCopy: @escaping (String) -> Void,
        onClear: @escaping () -> Void,
        onClose: @escaping () -> Void,
        initialQuery: String = "",
        recordHotkey: Hotkey = .defaultRecord
    ) {
        self.history = history
        self.onCopy = onCopy
        self.onClear = onClear
        self.onClose = onClose
        self.recordHotkey = recordHotkey
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            DotWindowHeader("History", subtitle: countText) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down")
                        .font(DotType.font(8.5, .bold))
                    Text("Newest first")
                        .font(DotType.font(10, .semibold))
                }
                .foregroundStyle(DotTheme.ink3.opacity(0.8))
                .accessibilityHidden(true)
            }

            hairline
            searchBar
            content
            footer
        }
        .frame(width: 620, height: 560)
        .background(DotPaper())
        .onAppear {
            appeared = true
            if !headless, !history.isEmpty {
                searchFocused = true
            }
        }
        .onChange(of: history) { _, newValue in
            guard newValue.isEmpty else { return }
            query = ""
            copiedID = nil
        }
        .onExitCommand { handleExit() }
        .onChange(of: tabTarget) { _, target in
            guard target != 0 else { return }
            searchFocused = true
            tabTarget = 0
        }
        .task(id: copyToken) {
            guard copiedID != nil else { return }
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            withAnimation(copyAnimation) { copiedID = nil }
        }
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(DotType.font(11, .semibold))
                .foregroundStyle(searchFocused ? DotTheme.accent : DotTheme.ink3)
                .frame(width: 14)
                .accessibilityHidden(true)

            TextField("Search transcripts", text: $query)
                .textFieldStyle(.plain)
                .font(DotType.font(12.5, .medium))
                .foregroundStyle(DotTheme.ink)
                .focused($searchFocused)
                .disabled(history.isEmpty)
                .accessibilityLabel("Search transcripts")
                .accessibilityHint("Filters the history as you type.")
                .onKeyPress(.tab, phases: [.down]) { _ in
                    guard !filtered.isEmpty else { return .ignored }
                    focusRequest += 1
                    return .handled
                }
                .onKeyPress(.downArrow, phases: [.down]) { _ in
                    guard !filtered.isEmpty else { return .ignored }
                    focusRequest += 1
                    return .handled
                }

            if !query.isEmpty {
                Button {
                    withAnimation(filterAnimation) { query = "" }
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(DotType.font(12, .semibold))
                        .foregroundStyle(DotTheme.ink3.opacity(0.58))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    searchClearFocused
                                        ? DotTheme.focusRing
                                        : Color.clear,
                                    lineWidth: 1.2
                                )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(DotPressStyle())
                .focused($searchClearFocused)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(searchFocused ? DotTheme.fieldFillFocused : DotTheme.fieldFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    searchFocused ? DotTheme.focusRing : DotTheme.fieldBorder,
                    lineWidth: searchFocused ? 1.2 : 1
                )
        )
        .shadow(
            color: DotTheme.accent.opacity(searchFocused ? 0.10 : 0),
            radius: 6,
            x: 0,
            y: 2
        )
        .opacity(history.isEmpty ? 0.62 : 1)
        .animation(.easeOut(duration: 0.15), value: searchFocused)
        .padding(.horizontal, DotTheme.windowPadding)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if history.isEmpty {
            emptyHistory
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            noMatches
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            transcriptList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var transcriptList: some View {
        HistoryTranscriptList(
            entries: filtered,
            copiedID: copiedID,
            rowVisible: rowVisible,
            reduceMotion: reduceMotion,
            headless: headless,
            onCopy: copy,
            onExit: handleExit,
            onTabForward: {
                // Buttons take keyboard focus only under Full Keyboard Access;
                // otherwise Tab wraps to the search field, as AppKit does.
                if NSApplication.shared.isFullKeyboardAccessEnabled {
                    clearFocused = true
                } else {
                    searchFocused = true
                }
            },
            onTabBackward: { tabTarget = 2 },
            focusRequest: focusRequest
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty states

    /// The empty window.
    ///
    /// There is no mark here. An empty window's largest element should be the
    /// one thing the person can do next, and a brand mark at 64 points above
    /// two lines of text is the biggest thing in a room with nothing in it.
    private var emptyHistory: some View {
        VStack(spacing: 0) {
            Text("No transcripts yet")
                .font(DotTheme.sectionFont)
                .foregroundStyle(DotTheme.ink)

            // The empty state states the fact and stops. The shortcut that
            // starts a recording is taught once, in the welcome tour, and the
            // menu carries it on the item that runs it; a third copy here was
            // the same sentence in a place where the person was looking for
            // something they had already recorded.
            Text("Finished recordings appear here.")
                .font(DotTheme.smallFont)
                .foregroundStyle(DotTheme.ink3)
                .padding(.top, 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("No transcripts yet")
        .accessibilityHint("Transcripts appear here once a recording is finished.")
    }

    private var noMatches: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DotTheme.accentSoft)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(DotTheme.cardBorder, lineWidth: 1)
                Image(systemName: "magnifyingglass")
                    .font(DotType.font(17, .semibold))
                    .foregroundStyle(DotTheme.accent)
            }
            .frame(width: 46, height: 46)
            .accessibilityHidden(true)

            Text("No matches")
                .font(DotTheme.sectionFont)
                .foregroundStyle(DotTheme.ink)
                .padding(.top, 14)

            Text("Nothing matches this search.")
                .font(DotTheme.smallFont)
                .foregroundStyle(DotTheme.ink3)
                .padding(.top, 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("No matches")
        .accessibilityHint("No transcript contains these words.")
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            hairline

            HStack(spacing: 10) {
                Button {
                    onClear()
                } label: {
                    Text("Clear history…")
                        .font(DotType.font(12, .semibold))
                        .foregroundStyle(
                            history.isEmpty
                                ? DotTheme.ink3
                                : DotTheme.coral
                        )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(history.isEmpty ? DotTheme.secondaryFill.opacity(0.55) : DotTheme.secondaryFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                clearFocused
                                    ? DotTheme.focusRing
                                    : DotTheme.coral.opacity(history.isEmpty ? 0.12 : 0.24),
                                lineWidth: clearFocused ? 1.5 : 1
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(DotPressStyle())
                .focused($clearFocused)
                .disabled(history.isEmpty)
                .accessibilityLabel("Clear history")
                .accessibilityHint("Removes every transcript after a confirmation.")
                .onKeyPress(.tab, phases: [.down]) { press in
                    guard press.modifiers.contains(.shift), !filtered.isEmpty else { return .ignored }
                    clearFocused = false
                    focusRequest += 1
                    return .handled
                }

                Spacer(minLength: 12)

                HStack(spacing: 5) {
                    Image(systemName: "lock.shield")
                        .font(DotType.font(9.5, .semibold))
                    Text("Kept on this Mac")
                        .font(DotType.font(10, .medium))
                }
                .foregroundStyle(DotTheme.ink3)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Transcripts are kept on this Mac.")
            }
            .padding(.horizontal, DotTheme.windowPadding)
            .frame(height: 56)
        }
    }

    // MARK: - Pieces

    private var hairline: some View {
        Rectangle()
            .fill(DotTheme.hairline)
            .frame(height: 1)
    }

    private var countText: String {
        switch history.count {
        case 0: "No transcripts"
        case 1: "1 transcript"
        default: "\(history.count) transcripts"
        }
    }

    private var entries: [Entry] {
        history.enumerated().map { Entry(id: $0.offset, text: $0.element) }
    }

    private var filtered: [Entry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.text.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    private var rowVisible: Bool {
        headless || appeared
    }

    private var filterAnimation: Animation? {
        guard !headless else { return nil }
        if reduceMotion {
            return .easeOut(duration: 0.16)
        }
        return .spring(response: 0.30, dampingFraction: 0.86)
    }

    private var copyAnimation: Animation? {
        if reduceMotion {
            return .easeOut(duration: 0.15)
        }
        return .spring(response: 0.28, dampingFraction: 0.80)
    }

    private func handleExit() {
        if query.isEmpty {
            onClose()
        } else {
            withAnimation(filterAnimation) { query = "" }
        }
    }

    private func copy(_ entry: Entry) {
        onCopy(entry.text)
        withAnimation(copyAnimation) { copiedID = entry.id }
        copyToken += 1
        AccessibilityNotification.Announcement("Copied").post()
    }

    struct Entry: Identifiable {
        let id: Int
        let text: String
    }
}

struct HistoryRowView: View {
    let entry: HistoryView.Entry
    let isCopied: Bool
    let isHovered: Bool
    let isFocused: Bool
    let rowVisible: Bool
    let reduceMotion: Bool
    let headless: Bool
    let animatesCopy: Bool
    let onCopy: () -> Void

    var body: some View {
        Button(action: onCopy) {
            HStack(alignment: .center, spacing: 12) {
                Text(entry.text)
                    .font(DotTheme.bodyFont)
                    .lineSpacing(2)
                    .foregroundStyle(DotTheme.ink)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                copyAffordance(copied: isCopied, hovered: isHovered)
                    .animation(
                        animatesCopy
                            ? (reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 0.80))
                            : nil,
                        value: isCopied
                    )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isHovered ? DotTheme.cardHoverFill : DotTheme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        borderColor(isFocused: isFocused, isCopied: isCopied),
                        lineWidth: isFocused ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(DotPressStyle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        .opacity(rowVisible ? 1 : 0)
        .offset(y: rowVisible || reduceMotion ? 0 : 10)
        .animation(entrance, value: rowVisible)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Transcript, \(entry.text)")
        .accessibilityValue(isCopied ? "Copied" : "")
        .accessibilityHint("Copies this transcript to the clipboard.")
    }

    private func borderColor(isFocused: Bool, isCopied: Bool) -> Color {
        if isFocused {
            return DotTheme.cardBorderSelected
        }
        if isCopied {
            return DotTheme.mint.opacity(0.70)
        }
        return DotTheme.cardBorder
    }

    private func copyAffordance(copied: Bool, hovered: Bool) -> some View {
        Group {
            if copied {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(DotType.font(8.5, .bold))
                    Text("Copied")
                        .font(DotType.font(10, .semibold))
                }
                .foregroundStyle(DotTheme.ink)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(Capsule().fill(DotTheme.mint.opacity(0.38)))
                .overlay(Capsule().strokeBorder(DotTheme.mint.opacity(0.75), lineWidth: 1))
                .transition(.opacity)
            } else {
                Image(systemName: "doc.on.doc")
                    .font(DotType.font(11, .semibold))
                    .foregroundStyle(hovered ? DotTheme.accent : DotTheme.ink3)
                    .frame(width: 27, height: 27)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(DotTheme.keycapFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(DotTheme.keycapBorder, lineWidth: 1)
                    )
                    .transition(.opacity)
            }
        }
        .frame(width: 70, alignment: .trailing)
        .accessibilityHidden(true)
    }

    private var entrance: Animation? {
        guard !headless else { return nil }
        let delay = Double(min(entry.id, 7)) * 0.04
        if reduceMotion {
            return .easeOut(duration: 0.18).delay(delay)
        }
        return .spring(response: 0.42, dampingFraction: 0.84).delay(delay)
    }
}

/// Headless renders draw the final frame immediately and never autofocus the
/// search field. The real window uses the default.
private struct HistoryHeadlessKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the history view is being drawn for an offscreen PNG.
    var historyHeadless: Bool {
        get { self[HistoryHeadlessKey.self] }
        set { self[HistoryHeadlessKey.self] = newValue }
    }
}
