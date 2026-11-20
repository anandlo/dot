import SwiftUI

/// The dot and the words that say what a check found.
///
/// The AI rewrite page and the Speech to text page draw the same shape: a small
/// indicator, then one short line of state. The spinner is the checking state;
/// the dot holds still in every settled state.
struct StatusChip: View {
    let title: String
    let dotTone: Color
    let textTone: Color
    let isChecking: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isChecking {
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
