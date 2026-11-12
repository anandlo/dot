import AppKit
import SwiftUI

/// One row of settings: a name, an optional fact under it, and the control that
/// changes it.
///
/// Every row in the app uses this shape, so a switch, a menu and a pair of
/// buttons sit on the same baseline and leave the same air around the hairline
/// below them. The horizontal inset belongs to the card; the row only owns its
/// vertical padding.
struct SettingsRow<Trailing: View>: View {
    /// The name of the setting.
    let title: String
    /// A concrete fact the title does not already state.
    var subtitle: String?
    /// An SF Symbol drawn before the title, at 16 points.
    var symbol: String?
    /// An application icon drawn before the title, at 20 points.
    var appIcon: NSImage?
    /// The colour of the title, for a row whose title is a value rather than a
    /// setting name.
    var titleTone: Color = DotTheme.ink
    /// The colour of the subtitle, for a line that reports a result.
    var subtitleTone: Color = DotTheme.ink3
    /// Whether the subtitle is drawn under the title and its control, across
    /// the row's whole width.
    ///
    /// A sentence that describes the control beside it has to share the row
    /// with that control, and a wide control leaves it a column too narrow to
    /// read. Two lines under a full-width row keep the sentence whole and the
    /// control where the person expects it.
    var wideSubtitle: Bool = false
    /// Whether the section above the row already says the row's name.
    ///
    /// A section called "Model" holding one row also called "Model" says the
    /// word twice in four lines. The row then is the control: the control takes
    /// the width of the card and keeps the accessible name it already had, and
    /// the heading over the card is what a reader sees. It is passed at the call
    /// site rather than guessed from the text: a duplicate is a fact about one
    /// card, and two rows that happen to share a word are not a duplicate.
    var isNamedBySection: Bool = false
    @ViewBuilder var trailing: Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        symbol: String? = nil,
        appIcon: NSImage? = nil,
        titleTone: Color = DotTheme.ink,
        subtitleTone: Color = DotTheme.ink3,
        wideSubtitle: Bool = false,
        isNamedBySection: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.appIcon = appIcon
        self.titleTone = titleTone
        self.subtitleTone = subtitleTone
        self.wideSubtitle = wideSubtitle
        self.isNamedBySection = isNamedBySection
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isNamedBySection {
                // The card is one control, and the heading over it already says
                // what the control sets. A labelled row would say it twice and
                // leave the control in a column beside a word it does not need,
                // so the control takes the width of the card instead.
                trailing
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: 12) {
                    if let appIcon {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                    } else if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(DotTheme.ink2)
                            .frame(width: 20, alignment: .leading)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13))
                            .foregroundStyle(titleTone)
                        if !wideSubtitle, let subtitle {
                            subtitleLine(subtitle)
                        }
                    }
                    // The words take the width they need before the gap beside
                    // the control is given any: without this the title column is
                    // offered half the row, and a sentence that fits on one line
                    // wraps at a width no reader would choose.
                    .layoutPriority(1)
                    Spacer(minLength: 16)
                    trailing
                }
            }
            if wideSubtitle, let subtitle {
                subtitleLine(subtitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 9)
        .frame(minHeight: 40)
    }

    /// One line of the fact under the title.
    private func subtitleLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(subtitleTone)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(
        _ title: String,
        subtitle: String? = nil,
        symbol: String? = nil,
        titleTone: Color = DotTheme.ink,
        subtitleTone: Color = DotTheme.ink3
    ) {
        self.init(
            title,
            subtitle: subtitle,
            symbol: symbol,
            titleTone: titleTone,
            subtitleTone: subtitleTone
        ) {
            EmptyView()
        }
    }
}

/// The hairline between two rows.
///
/// It is one device pixel, not one point: at two times scale a 1 pt rectangle
/// is a two pixel band, which is heavier than any divider macOS draws.
struct SettingsDivider: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(DotTheme.hairline)
            .frame(height: 1 / max(displayScale, 1))
    }
}

/// A titled group of rows.
///
/// The title sits above the card rather than inside it: a header inside the card
/// competes with the first row for the same weight, and it has to be repeated in
/// every card. It is set in the page title's serif one rank down and aligned
/// with the card's own leading edge, so a page reads as a sequence of titled
/// cards rather than a field of labels. The card supplies the inset, so the
/// header stays outside it: the title belongs to the whole card, not to the
/// column of words inside it.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(DotTheme.displayFont(17))
                .foregroundStyle(DotTheme.ink)
                .accessibilityAddTraits(.isHeader)
            DotCard {
                VStack(spacing: 0) {
                    content
                }
            }
        }
        // The page stacks its sections 22 points apart. A title is larger than a
        // row title, and a card under it needs more air over it than a label
        // did: the extra 8 makes the space between one card and the next title
        // 30 points, which is what the larger line wants.
        .padding(.top, 8)
    }
}
