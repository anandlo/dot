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
    @ViewBuilder var trailing: Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        symbol: String? = nil,
        appIcon: NSImage? = nil,
        titleTone: Color = DotTheme.ink,
        subtitleTone: Color = DotTheme.ink3,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.appIcon = appIcon
        self.titleTone = titleTone
        self.subtitleTone = subtitleTone
        self.trailing = trailing()
    }

    var body: some View {
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
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(subtitleTone)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            trailing
        }
        .padding(.vertical, 9)
        .frame(minHeight: 40)
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
/// The title sits above the card rather than inside it: a header inside the
/// card competes with the first row for the same weight, and it has to be
/// repeated in every card. The card supplies the inset, so the header is
/// indented to the same edge as the row titles.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DotTheme.ink2)
                .padding(.leading, 16)
                .accessibilityAddTraits(.isHeader)
            DotCard {
                VStack(spacing: 0) {
                    content
                }
            }
        }
    }
}
