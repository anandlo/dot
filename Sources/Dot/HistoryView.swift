import DotCore
import SwiftUI

/// The History window: the transcripts Dot remembers, on warm paper.
///
/// The view is only a surface. It receives the history newest first, reports a
/// copy or a clear through its callbacks, and closes through `onClose`. It
/// never reads the history file, the clipboard or the Keychain itself, and it
/// draws no timestamps because the store only keeps strings.
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
    @State private var hoveredID: Int?
    @State private var copiedID: Int?
    @State private var copyToken = 0
    @FocusState private var searchFocused: Bool
    @FocusState private var searchClearFocused: Bool
    @FocusState private var focusedID: Int?
    @FocusState private var clearFocused: Bool

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
                        .font(.system(size: 8.5, weight: .bold))
                    Text("Newest first")
                        .font(.system(size: 10, weight: .medium))
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
        .onExitCommand {
            if query.isEmpty {
                onClose()
            } else {
                withAnimation(filterAnimation) { query = "" }
            }
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(searchFocused ? DotTheme.accent : DotTheme.ink3)
                .frame(width: 14)
                .accessibilityHidden(true)

            TextField("Search transcripts", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(DotTheme.ink)
                .focused($searchFocused)
                .disabled(history.isEmpty)
                .accessibilityLabel("Search transcripts")
                .accessibilityHint("Filters the history as you type.")

            if !query.isEmpty {
                Button {
                    withAnimation(filterAnimation) { query = "" }
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
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
                .buttonStyle(.plain)
                .focused($searchClearFocused)
                .accessibilityLabel("Clear search")
                .help("Clear search")
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

    private var content: some View {
        ZStack {
            if history.isEmpty {
                emptyHistory
                    .transition(.opacity)
            } else if filtered.isEmpty {
                noMatches
                    .transition(.opacity)
            } else {
                transcriptList
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(filterAnimation, value: query)
    }

    private var transcriptList: some View {
        ScrollView(.vertical) {
            VStack(spacing: 8) {
                ForEach(filtered) { entry in
                    row(entry)
                }
            }
            .padding(.horizontal, DotTheme.windowPadding)
            .padding(.top, 8)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Transcripts, newest first")
    }

    private func row(_ entry: Entry) -> some View {
        let isHovered = hoveredID == entry.id
        let isCopied = copiedID == entry.id
        let isFocused = focusedID == entry.id

        return Button {
            copy(entry)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Text(entry.text)
                    .font(DotTheme.bodyFont)
                    .lineSpacing(2)
                    .foregroundStyle(DotTheme.ink)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                copyAffordance(copied: isCopied, hovered: isHovered)
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
            .shadow(
                color: DotTheme.cardShadow,
                radius: isHovered ? 12 : 8,
                x: 0,
                y: isHovered ? 5 : 3
            )
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($focusedID, equals: entry.id)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                if hovering {
                    hoveredID = entry.id
                } else if hoveredID == entry.id {
                    hoveredID = nil
                }
            }
        }
        .scaleEffect(isHovered && !reduceMotion ? 1.004 : 1)
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .opacity(rowVisible ? 1 : 0)
        .offset(y: rowVisible || reduceMotion ? 0 : 10)
        .animation(entrance(entry.id), value: appeared)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Transcript, \(entry.text)")
        .accessibilityValue(isCopied ? "Copied" : "")
        .accessibilityHint("Copies this transcript to the clipboard.")
        .help("Copy transcript")
        .transition(rowTransition)
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
                        .font(.system(size: 8.5, weight: .bold))
                    Text("Copied")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(DotTheme.ink)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(Capsule().fill(DotTheme.mint.opacity(0.38)))
                .overlay(Capsule().strokeBorder(DotTheme.mint.opacity(0.75), lineWidth: 1))
                .transition(.opacity)
            } else {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
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

            Text("Press \(recordHotkey.label) to record.")
                .font(DotTheme.smallFont)
                .foregroundStyle(DotTheme.ink3)
                .padding(.top, 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("No transcripts yet")
        .accessibilityHint("Press \(recordHotkey.spelledOut) to record.")
    }

    private var noMatches: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DotTheme.accentSoft)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(DotTheme.cardBorder, lineWidth: 1)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(DotTheme.accent)
            }
            .frame(width: 46, height: 46)
            .accessibilityHidden(true)

            Text("No matches")
                .font(DotTheme.sectionFont)
                .foregroundStyle(DotTheme.ink)
                .padding(.top, 14)

            Text("Try another word, or clear the search.")
                .font(DotTheme.smallFont)
                .foregroundStyle(DotTheme.ink3)
                .padding(.top, 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("No matches")
        .accessibilityHint("Try another word, or clear the search.")
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            hairline

            HStack(spacing: 10) {
                Button {
                    onClear()
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(history.isEmpty ? DotTheme.ink3.opacity(0.35) : DotTheme.coral)
                            .frame(width: 5, height: 5)
                        Text("Clear history…")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(history.isEmpty ? DotTheme.ink3 : DotTheme.ink)
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
                .buttonStyle(HistoryPressStyle())
                .focused($clearFocused)
                .disabled(history.isEmpty)
                .accessibilityLabel("Clear history")
                .accessibilityHint("Removes every transcript after a confirmation.")
                .help("Clear every transcript")

                Spacer(minLength: 12)

                HStack(spacing: 5) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 9.5, weight: .medium))
                    Text("Kept on this Mac")
                        .font(.system(size: 10))
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
        history.count == 1 ? "1 transcript" : "\(history.count) transcripts"
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

    private var rowTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .top)),
            removal: .opacity
        )
    }

    private func entrance(_ index: Int) -> Animation? {
        guard !headless else { return nil }
        let delay = Double(min(index, 7)) * 0.04
        if reduceMotion {
            return .easeOut(duration: 0.18).delay(delay)
        }
        return .spring(response: 0.42, dampingFraction: 0.84).delay(delay)
    }

    private func copy(_ entry: Entry) {
        onCopy(entry.text)
        withAnimation(copyAnimation) { copiedID = entry.id }
        copyToken += 1
        AccessibilityNotification.Announcement("Copied").post()
    }

    private struct Entry: Identifiable {
        let id: Int
        let text: String
    }
}

/// The clear button only needs the press motion; its colours are set by the
/// view so the disabled state reads on paper without a stock control.
private struct HistoryPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.75), value: configuration.isPressed)
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
