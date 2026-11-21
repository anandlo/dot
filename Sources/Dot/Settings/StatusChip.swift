import SwiftUI

/// The dot and the words that say what a check found.
///
/// The AI rewrite page and the Speech to text page draw the same shape: a small
/// indicator, then one short line of state. The spinner is the checking state;
/// the dot holds still in every settled state, and in the checking state too
/// when the system asks for less motion, because the system spinner keeps
/// turning regardless of that setting.
struct StatusChip: View {
    let title: String
    let dotTone: Color
    let textTone: Color
    let isChecking: Bool

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.statusChipReduceMotion) private var reduceMotionOverride

    var body: some View {
        HStack(spacing: 6) {
            if isChecking && !(reduceMotionOverride ?? systemReduceMotion) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            } else {
                Circle()
                    .fill(dotTone)
                    .frame(width: 6, height: 6)
            }
            Text(title)
                .font(DotType.font(11.5, .medium))
                .foregroundStyle(textTone)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A render or a test can ask for one appearance of the motion rule, which the
/// system's own setting only offers to the whole app.
private struct StatusChipReduceMotionKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var statusChipReduceMotion: Bool? {
        get { self[StatusChipReduceMotionKey.self] }
        set { self[StatusChipReduceMotionKey.self] = newValue }
    }
}
