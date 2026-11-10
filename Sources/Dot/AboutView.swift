import AppKit
import SwiftUI

/// The app's fixed public destinations.
///
/// Defined once because the About window and the About page both show them, and
/// two copies of a URL is how one of them ends up pointing somewhere stale.
enum DotLinks {
    static let github = URL(string: "https://github.com/anandlo/dot")!
    static let website = URL(string: "https://dot.anandlo.com")!
    static let buyMeACoffee = URL(string: "https://buymeacoffee.com/anandlo")!
    static let tagline = "Write as fast as you can think."

    /// GitHub shown without its scheme, which is how people write it.
    static var displayGitHub: String {
        github.absoluteString.replacingOccurrences(of: "https://", with: "")
    }

    static var displayBuyMeACoffee: String {
        "buymeacoffee.com/anandlo"
    }
}

/// One destination in an About page: a label, an optional detail and a trailing
/// symbol.
///
/// Rows rather than buttons, because these are places to go, not commands to
/// run. The hover wash is what tells the user the whole row is the target.
@MainActor
struct AboutActionRow: View {
    /// What the destination is called.
    let title: String
    /// A short hint about where it goes, shown dimmed on the right.
    var detail: String? = nil
    /// An SF Symbol drawn at the trailing edge.
    let symbol: String
    /// What the row does when it is chosen.
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
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
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DotTheme.ink3)
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? DotTheme.fieldFill : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
    }
}

/// The identity block shared by the About window and the About page.
///
/// The mark sits with the name rather than above a centred stack: the page is a
/// settings page, and a hero centred in the middle of it left half the window
/// empty.
@MainActor
struct AboutIdentity: View {
    let version: String
    let tagline: String

    var body: some View {
        // Centred over the rows beneath it. Ranged left, the block left the
        // whole right half of the page empty and read as a stray label rather
        // than as the identity of the thing you are looking at.
        HStack(alignment: .center, spacing: 16) {
            Spacer(minLength: 0)
            DotSignalMark(size: 64, animated: true)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Dot")
                    .font(DotTheme.displayFont(26))
                    .tracking(-0.4)
                    .foregroundStyle(DotTheme.ink)
                    .accessibilityAddTraits(.isHeader)

                Text("Beta version")
                    .font(.system(size: 11.5, weight: .medium))
                    .tracking(0.2)
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

/// The About window.
///
/// It is the same composition as the About page in settings: the identity block
/// and the same destination rows. A centred splash with a row of buttons was a
/// second design to keep in sync, and it printed the tagline twice.
@MainActor
struct AboutView: View {
    /// The version to show, exactly as the bundle declares it.
    let version: String
    /// Opens the welcome window.
    let onWelcome: () -> Void
    /// Opens the settings window.
    let onOpenSettings: () -> Void
    /// Reveals the log in Finder.
    let onOpenLog: () -> Void
    /// Closes this window.
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AboutIdentity(version: version, tagline: DotLinks.tagline)

            DotCard(padding: 8) {
                VStack(spacing: 0) {
                    AboutActionRow(
                        title: "Check for updates…",
                        symbol: "arrow.triangle.2.circlepath"
                    ) {
                        UpdateController.shared.checkForUpdates(userInitiated: true)
                    }
                    hairline
                    AboutActionRow(
                        title: "Support Dot",
                        detail: DotLinks.displayBuyMeACoffee,
                        symbol: "cup.and.saucer.fill"
                    ) {
                        NSWorkspace.shared.open(DotLinks.buyMeACoffee)
                    }
                    hairline
                    AboutActionRow(
                        title: "GitHub",
                        detail: DotLinks.displayGitHub,
                        symbol: "arrow.up.right"
                    ) {
                        NSWorkspace.shared.open(DotLinks.github)
                    }
                    hairline
                    AboutActionRow(
                        title: "Website",
                        detail: DotLinks.website.host,
                        symbol: "globe"
                    ) {
                        NSWorkspace.shared.open(DotLinks.website)
                    }
                    hairline
                    AboutActionRow(
                        title: "Show welcome tour",
                        symbol: "sparkles",
                        action: onWelcome
                    )
                    hairline
                    AboutActionRow(
                        title: "Open settings",
                        symbol: "gearshape",
                        action: onOpenSettings
                    )
                    hairline
                    AboutActionRow(
                        title: "Open log",
                        symbol: "doc.text.magnifyingglass",
                        action: onOpenLog
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DotTheme.windowPadding)
        .padding(.top, 40)
        .padding(.bottom, DotTheme.windowPadding)
        .frame(width: 520, height: 368, alignment: .topLeading)
        .background(DotPaper())
        .onExitCommand(perform: onClose)
    }

    private var hairline: some View {
        Rectangle()
            .fill(DotTheme.hairline)
            .frame(height: 1)
            .padding(.leading, 4)
    }
}
