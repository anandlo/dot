import AppKit
import DotCore
import SwiftUI

// MARK: - This build

/// What the About window says about the build it is drawn in.
///
/// The version comes from ``ProductVersion`` and the build number from the
/// bundle, so the page cannot disagree with the binary or with the update
/// check. A binary that was not assembled into a bundle reports the version
/// type's own `unknown` rather than a number nobody can check.
enum AboutInfo {
    /// The build number the bundle declares.
    static var build: String {
        let declared = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let trimmed = declared?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? ProductVersion.unknown : trimmed
    }

    /// The macOS version running the app.
    static var operatingSystem: String {
        operatingSystem(ProcessInfo.processInfo.operatingSystemVersion)
    }

    /// A system version as the line writes it, with the patch number only when
    /// it says something.
    static func operatingSystem(_ version: OperatingSystemVersion) -> String {
        guard version.patchVersion != 0 else {
            return "\(version.majorVersion).\(version.minorVersion)"
        }
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// The line someone pastes into a bug report.
    static func copyLine(version: String, build: String, macOS: String) -> String {
        "Dot \(version) (\(build)), macOS \(macOS)"
    }
}

/// What the update row is showing.
enum AboutUpdateState: Equatable, Sendable {
    /// Nothing has been asked yet.
    case idle
    /// A request is in flight.
    case checking
    /// The running build is the newest release.
    case upToDate
    /// A newer release exists, with its page when the response named one.
    case available(version: String, page: URL?)
    /// The request did not produce a release.
    case unreachable
}

// MARK: - Rows

/// The soft square behind a row's symbol.
private struct AboutRowIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DotTheme.ink2)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(DotTheme.cardSelectedFill)
            )
            .accessibilityHidden(true)
    }
}

/// The wash a row takes under the pointer, and the shape that makes the whole
/// row the target rather than only its words.
private struct AboutRowSurface: ViewModifier {
    let hovering: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering ? DotTheme.cardHoverFill : Color.clear)
            )
            .contentShape(Rectangle())
    }
}

// MARK: - The shared list

/// One destination in an About surface: a symbol, a label, an optional detail
/// and a trailing mark.
///
/// A row rather than a button, because these are places to go, not commands to
/// run. The hover wash is what tells the person the whole row is the target.
@MainActor
struct AboutActionRow: View {
    /// What the destination is called.
    let title: String
    /// A short hint about where it goes, shown dimmed on the right.
    var detail: String? = nil
    /// An SF Symbol drawn in the leading chip.
    let symbol: String
    /// Whether the row leaves Dot for a browser, which changes the trailing
    /// mark from a chevron to the outbound arrow.
    var external: Bool = false
    /// What the row does when it is chosen.
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AboutRowIcon(symbol: symbol)
                Text(title)
                    .font(DotTheme.bodyFont)
                    .foregroundStyle(DotTheme.ink)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(DotTheme.smallFont)
                        .foregroundStyle(DotTheme.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Image(systemName: external ? "arrow.up.right" : "chevron.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(DotTheme.ink3)
            }
            .modifier(AboutRowSurface(hovering: hovering))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
    }
}

/// The identity block on the About page in Settings.
///
/// The same mark and the same words as the About window, at settings scale:
/// two surfaces that name the product must not draw it two ways.
@MainActor
struct AboutIdentity: View {
    /// The version to show, exactly as the bundle declares it.
    let version: String
    /// The line under the name.
    let tagline: String

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Spacer(minLength: 0)
            DotMarkDialPresentation(dial: DotMark.chosenDial ?? .clipped, size: 52)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Dot")
                    .font(DotTheme.displayFont(24))
                    .tracking(-0.4)
                    .foregroundStyle(DotTheme.ink)
                    .accessibilityAddTraits(.isHeader)

                Text(version)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(DotTheme.ink3)

                Text(tagline)
                    .font(DotTheme.bodyFont)
                    .foregroundStyle(DotTheme.ink2)
                    .padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - The window

/// The About window.
///
/// Three parts: the mark and the build it belongs to, the places Dot lives,
/// and the small print. The mark is drawn from ``DotMark`` rather than loaded
/// from an icon file, so the window shows the vectors the app icon is made
/// from instead of a bitmap at a size where it can only be a downscale.
@MainActor
struct AboutView: View {
    /// The content size the window reserves.
    static let size = CGSize(width: 540, height: 620)

    /// The mark's plate, in points.
    private static let markSize: CGFloat = 76

    /// The version to show, exactly as the bundle declares it.
    var version: String = ProductVersion.current
    /// The build number the bundle declares.
    var build: String = AboutInfo.build
    /// Whether the mark enters on a spring. Renders pass `false`.
    var animated = true
    /// A state to draw instead of asking GitHub. Renders pass one.
    var previewUpdate: AboutUpdateState? = nil
    /// Closes this window.
    var onClose: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false
    @State private var copied = false
    @State private var update: AboutUpdateState = .idle
    @State private var updateHovering = false

    var body: some View {
        VStack(spacing: 0) {
            mark
            identity
            oneLiner
            destinations
            Spacer(minLength: 12)
            footer
        }
        .padding(.horizontal, 30)
        .padding(.top, 28)
        .padding(.bottom, 18)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(DotPaper())
        .background(closeShortcut)
        .onAppear(perform: enter)
        .onExitCommand(perform: onClose)
    }

    /// Cmd-W, from the view rather than from a menu.
    ///
    /// Dot is a menu bar app with no menu bar of its own, so there is no
    /// File > Close to carry the standard key. The window answers it here, next
    /// to the Escape that ``onExitCommand`` already handles.
    private var closeShortcut: some View {
        Button("Close", action: onClose)
            .keyboardShortcut("w", modifiers: .command)
            .opacity(0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    /// The shipped mark, large, with the icon's own corner and shadow.
    ///
    /// The squircle stroke is the plate's edge. On dark paper the plate's foot
    /// is within a few points of the background, and without that hairline the
    /// mark reads as a white dot floating on nothing instead of as a disc cut
    /// by a plate.
    private var mark: some View {
        DotMarkDialPresentation(dial: DotMark.chosenDial ?? .clipped, size: Self.markSize)
            .overlay(
                DotSquircle()
                    .stroke(DotTheme.markEdge, lineWidth: 1)
                    .padding(Self.markSize * DotIconPresentation.paddingRatio)
            )
            .scaleEffect(markScale)
            .opacity(markOpacity)
            .accessibilityHidden(true)
    }

    /// The mark arrives from 96% rather than from nothing, so the entrance
    /// reads as the page settling instead of as a picture loading.
    private var markScale: CGFloat {
        guard animated, !reduceMotion, !entered else { return 1 }
        return 0.96
    }

    private var markOpacity: Double {
        entered || !animated ? 1 : 0
    }

    private func enter() {
        guard !entered else { return }
        guard animated else {
            entered = true
            return
        }
        // Reduce Motion keeps the change of state and drops the movement: the
        // mark fades in where it sits instead of arriving from 96%.
        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.18)
            : .spring(response: 0.52, dampingFraction: 0.76)
        withAnimation(animation) {
            entered = true
        }
    }

    /// The name, the promise and the build, centred under the mark.
    private var identity: some View {
        VStack(spacing: 0) {
            Text("Dot")
                .font(DotTheme.displayFont(38))
                .tracking(-0.6)
                .foregroundStyle(DotTheme.ink)
                .accessibilityAddTraits(.isHeader)

            Text(ProductLinks.tagline)
                .font(.system(size: 13))
                .foregroundStyle(DotTheme.ink2)
                .padding(.top, 4)

            versionLine
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
    }

    /// The version, the build and the one button a bug report needs.
    private var versionLine: some View {
        HStack(spacing: 8) {
            Text("\(version) (\(build))")
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(DotTheme.ink3)
                .textSelection(.enabled)

            Button(action: copyVersion) {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(copied ? "Copied" : "Copy")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(copied ? DotTheme.ink : DotTheme.ink3)
                .frame(width: 60, height: 18)
                .background(
                    Capsule(style: .continuous)
                        .fill(DotTheme.secondaryFill)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(DotTheme.secondaryBorder, lineWidth: 1)
                )
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy version information")
            .accessibilityValue(copied ? "Copied" : "")
            .help("Copies the version, the build and the macOS version for a bug report.")
        }
    }

    /// What a take is, in one sentence.
    private var oneLiner: some View {
        Text("Press once, speak, press again. Dot types at the cursor.")
            .font(.system(size: 12.5))
            .foregroundStyle(DotTheme.ink2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 18)
    }

    private func copyVersion() {
        let line = AboutInfo.copyLine(
            version: version,
            build: build,
            macOS: AboutInfo.operatingSystem
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(line, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) {
            copied = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.easeOut(duration: 0.2)) {
                copied = false
            }
        }
    }

    /// Where Dot lives, and the one action that reaches the network.
    private var destinations: some View {
        DotCard(padding: 6) {
            VStack(spacing: 0) {
                AboutActionRow(
                    title: "Website",
                    detail: ProductLinks.displayWebsite,
                    symbol: "globe",
                    external: true
                ) {
                    NSWorkspace.shared.open(ProductLinks.website)
                }
                separator
                AboutActionRow(
                    title: "GitHub",
                    detail: ProductLinks.displayGitHub,
                    symbol: "chevron.left.forwardslash.chevron.right",
                    external: true
                ) {
                    NSWorkspace.shared.open(ProductLinks.github)
                }
                separator
                AboutActionRow(
                    title: "Report an issue",
                    detail: ProductLinks.displayIssues,
                    symbol: "exclamationmark.bubble",
                    external: true
                ) {
                    NSWorkspace.shared.open(ProductLinks.newIssue)
                }
                separator
                AboutActionRow(
                    title: "Support Dot",
                    detail: ProductLinks.displaySupport,
                    symbol: "cup.and.saucer.fill",
                    external: true
                ) {
                    NSWorkspace.shared.open(ProductLinks.support)
                }
                separator
                AboutActionRow(
                    title: "Licence",
                    detail: ProductLinks.licenceName,
                    symbol: "doc.text",
                    external: true
                ) {
                    NSWorkspace.shared.open(ProductLinks.licence)
                }
                separator
                updateRow
            }
        }
        .padding(.top, 20)
    }

    /// A hairline between rows, inset to the label rather than to the card.
    private var separator: some View {
        Rectangle()
            .fill(DotTheme.hairline)
            .frame(height: 1)
            .padding(.leading, 42)
    }

    /// The same check the menu runs, answering in place instead of in an
    /// alert, and opening the release page once one is known.
    private var updateRow: some View {
        Button(action: performUpdate) {
            HStack(spacing: 10) {
                AboutRowIcon(symbol: "arrow.triangle.2.circlepath")
                Text(updateTitle)
                    .font(DotTheme.bodyFont)
                    .foregroundStyle(DotTheme.ink)
                Spacer(minLength: 8)
                updateStatus
            }
            .modifier(AboutRowSurface(hovering: updateHovering))
        }
        .buttonStyle(.plain)
        .onHover { updateHovering = $0 }
        .accessibilityLabel(updateTitle)
        .accessibilityValue(updateStatusText)
    }

    /// What the row is showing: the preview's state when one was supplied,
    /// otherwise what the last check found.
    private var currentUpdate: AboutUpdateState {
        previewUpdate ?? update
    }

    private var isChecking: Bool {
        currentUpdate == .checking
    }

    private var updateTitle: String {
        if case .available(let version, _) = currentUpdate {
            return "Dot \(version) is available"
        }
        return "Check for updates"
    }

    private var updateStatusText: String {
        switch currentUpdate {
        case .idle: return "Not checked yet"
        case .checking: return "Checking"
        case .upToDate: return "Up to date"
        case .available(let version, _): return "Version \(version) is available"
        case .unreachable: return "Could not reach GitHub"
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch currentUpdate {
        case .idle:
            Text("Check now")
                .font(DotTheme.smallFont)
                .foregroundStyle(DotTheme.ink3)
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 12, height: 12)
                Text("Checking…")
                    .font(DotTheme.smallFont)
                    .foregroundStyle(DotTheme.ink3)
            }
        case .upToDate:
            HStack(spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                Text("Up to date")
                    .font(DotTheme.smallFont)
            }
            .foregroundStyle(DotTheme.ink3)
        case .available:
            HStack(spacing: 5) {
                Text("View release")
                    .font(.system(size: 11.5, weight: .semibold))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(DotTheme.ink)
        case .unreachable:
            Text("Could not reach GitHub")
                .font(DotTheme.smallFont)
                .foregroundStyle(DotTheme.ink3)
        }
    }

    private func performUpdate() {
        guard previewUpdate == nil else { return }
        if case .available(_, let page) = currentUpdate {
            NSWorkspace.shared.open(page ?? ProductLinks.website)
            return
        }
        guard !isChecking else { return }
        update = .checking
        Task { @MainActor in
            let result = await UpdateController.shared.check()
            switch result {
            case .upToDate:
                update = .upToDate
            case .newer(let version, let page):
                update = .available(version: version, page: page)
            case .failed:
                update = .unreachable
            }
        }
    }

    /// The small print: what a take does, who made the app, and the notice.
    private var footer: some View {
        VStack(spacing: 10) {
            Text(privacy)
                .font(.system(size: 11))
                .foregroundStyle(DotTheme.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)

            VStack(spacing: 2) {
                Text("Made by \(ProductLinks.author).")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DotTheme.ink2)

                Text(ProductLinks.copyright)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DotTheme.ink3)
            }
        }
    }

    /// Each clause is what the code does: the chosen provider is the only
    /// destination for audio, Apple Speech transcribes inside the machine, the
    /// keys are Keychain items, and the history is one file in Application
    /// Support. Nothing further is promised here, so the line cannot drift into
    /// a claim the binary does not keep.
    private var privacy: String {
        "Audio is sent only to the engine you pick, and Apple Speech runs on this Mac. "
            + "API keys are kept in the Keychain. Your transcript history is a file on this Mac."
    }
}
