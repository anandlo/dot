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
    /// An explanation attached to the name and to the control, shown as a
    /// tooltip and spoken by VoiceOver when either one has focus.
    var help: String?
    /// An SF Symbol drawn before the title, at 16 points.
    var symbol: String?
    /// An application icon drawn before the title, at 20 points.
    var appIcon: NSImage?
    /// The colour of the title, for a row whose title is a value rather than a
    /// setting name.
    var titleTone: Color = DotTheme.ink
    /// The colour of the subtitle, for a line that reports a result.
    var subtitleTone: Color = DotTheme.ink2
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
        help: String? = nil,
        symbol: String? = nil,
        appIcon: NSImage? = nil,
        titleTone: Color = DotTheme.ink,
        subtitleTone: Color = DotTheme.ink2,
        wideSubtitle: Bool = false,
        isNamedBySection: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.help = help
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
                    .settingsHelp(help)
            } else {
                HStack(alignment: .center, spacing: 12) {
                    if let appIcon {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                    } else if let symbol {
                        Image(systemName: symbol)
                            .font(DotType.font(16, .medium))
                            .foregroundStyle(DotTheme.ink2)
                            .frame(width: 20, alignment: .leading)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(DotType.font(13, .medium))
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
                    .settingsHelp(help)
                    Spacer(minLength: 16)
                    trailing
                        .settingsHelp(help)
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
    ///
    /// Set in the tabular face because a subtitle often carries a number: how
    /// many recordings taught the level meter, how many models the service
    /// answered, how many keys a voice needs. The digits are the same size as
    /// the words, and they keep their column when the number changes.
    private func subtitleLine(_ text: String) -> some View {
        Text(text)
            .font(DotType.tabularFont(11, .medium))
            .foregroundStyle(subtitleTone)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsRowHelpKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var settingsRowHelp: String? {
        get { self[SettingsRowHelpKey.self] }
        set { self[SettingsRowHelpKey.self] = newValue }
    }
}

private extension View {
    @ViewBuilder
    func settingsHelp(_ text: String?) -> some View {
        if let text {
            self.help(text)
                .accessibilityHint(text)
                .environment(\.settingsRowHelp, text)
        } else {
            self
        }
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(
        _ title: String,
        subtitle: String? = nil,
        help: String? = nil,
        symbol: String? = nil,
        titleTone: Color = DotTheme.ink,
        subtitleTone: Color = DotTheme.ink2
    ) {
        self.init(
            title,
            subtitle: subtitle,
            help: help,
            symbol: symbol,
            titleTone: titleTone,
            subtitleTone: subtitleTone
        ) {
            EmptyView()
        }
    }
}

/// The explanations the settings rows share with their tests.
enum SettingsExplanation {
    static let calibrationHelp =
        "Dot learns this microphone's background noise to set the level meter's floor and the threshold for trimming silence at the ends of a take. Reset clears what it learned; microphone gain is never changed."
    static let recordingModeSubtitle = "Press to toggle, or hold to record."
    static let pasteSubtitle = "When off, Dot copies the transcript without pasting."
    static let menuBarRecordSubtitle =
        "Clicking the icon starts and stops recording instead of opening the menu."
    static let launchSubtitle = "Starts Dot when you log in to your Mac."
    static let logTranscriptsSubtitle = "Writes transcript text to Dot.log for troubleshooting."
    static let historySubtitle = "How many recent transcripts Dot keeps in History."
    static let microphoneSubtitle = "The input Dot records from."
    static let calibrationSubtitle = "Sets the meter floor and the threshold for trimming silent ends."
    static let formatSubtitle = "Adapts pasted text to the app where you start dictating."
    static let standingRulesSubtitle = "Adds these rules to the end of each Agent prompt Dot writes."
    static let calibrationNone = "Not learned yet."
    static let calibrationOne = "Learned from 1 recording."
    static let dwellSubtitle = "How long results stay on the island."
    static let dwellHelp =
        "Pasted results close after at most 3.5 seconds. Hovering, scrolling or editing the card pauses the countdown, and a rewrite card stays at least 60 seconds."
    static let historyHelp =
        "How many recent transcripts Dot keeps in ~/Library/Application Support/Dot/history.json. Older ones are removed from that file."
    static let formatHelp =
        "Dot formats pasted text for the app where you started dictating. History keeps the original transcript."
    static let segmentSubtitle =
        "Longer recordings are sent in parts of this length."
    static let segmentHelp =
        "Service default uses the longest stretch the service accepts, and a longer choice is capped at that limit."
    static let temperatureHelp =
        "Lower values keep the transcript literal and consistent; higher values let the model vary its wording."
    static let authHelp =
        "How the API key is sent: as an Authorization: Bearer header or as an api-key header."
    static let regionHelp =
        "The Azure region your Speech resource was created in. A key works only in its own region."
    static let planHelp =
        "Token Plan keys start with tp- or ttp- and use the Token Plan address. Pasting one selects this plan."
    static let reasoningHelp =
        "How much the model reasons before the assistant answers. Rewrites ask for the lightest level the model publishes."
    static let standingRulesHelp =
        "Dot appends these rules to Agent prompts after generation. It doesn’t send them to the model."
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
