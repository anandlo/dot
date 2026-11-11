import DotCore
import SwiftUI

/// The three moments of the loop the welcome tour walks through.
enum TourStep: Int, CaseIterable, Identifiable {
    case hold
    case speak
    case paste

    var id: Int { rawValue }

    /// The instruction the step makes. The shortcut is handed in, never
    /// written out here: it is a setting.
    ///
    /// - Parameters:
    ///   - shortcut: the label of the record shortcut as configured.
    ///   - mode: how the person starts and ends a recording. The last step is
    ///     the one that names it: in hold mode the release ends the take, in
    ///     toggle mode the next press does.
    func title(shortcut: String, mode: RecordingMode) -> String {
        switch self {
        case .hold: "Press \(shortcut) to start"
        case .speak: "Speak naturally"
        case .paste: mode == .hold ? "Let go to paste" : "Press again to paste"
        }
    }

    /// One line under the title.
    ///
    /// - Parameter mode: how the person starts and ends a recording. The middle
    ///   step is where the recording ends, so it has to describe the interaction
    ///   the person chose rather than the one Dot shipped.
    func detail(mode: RecordingMode) -> String {
        switch self {
        case .hold: "The island appears wherever you are."
        case .speak:
            mode == .hold
                ? "Your words appear as you talk. Let go of the shortcut to stop."
                : "Your words appear as you talk. Press the shortcut again to stop."
        case .paste: "The text lands right at your cursor."
        }
    }

    /// How long one pass of the step's scene lasts, in seconds.
    var cycle: Double {
        switch self {
        case .hold: 7.5
        case .speak: 8.2
        case .paste: 8.2
        }
    }

    /// The moment a still render captures.
    var stillTime: Double {
        switch self {
        case .hold: 3.5
        case .speak: 5.6
        case .paste: 5.6
        }
    }
}

/// One frame of the dictated sentence, a pure function of time.
struct TourFrame: Equatable {
    let phase: Double
    let level: Double
    let pulse: Double
    let time: Double
    let spoken: [TourFrame.Word]

    static let sentence = "Remind me to send the notes before Friday."
    static let duration: Double = 8

    struct Word: Equatable {
        let text: String
        let start: Int
        let length: Int
        let loudness: Double
    }

    static let words: [Word] = {
        var words: [Word] = []
        var start = 0
        for piece in sentence.split(separator: " ", omittingEmptySubsequences: false) {
            let text = String(piece)
            let coarse = SpeechShape.field(Double(words.count) * 2.7, 17.0)
            let fine = SpeechShape.field(Double(words.count) * 1.13 + 5, 31.0)
            let loudness = 0.34 + 0.66 * (0.58 * coarse + 0.42 * fine)
            words.append(Word(text: text, start: start, length: text.count, loudness: loudness))
            start += text.count + 1
        }
        return words
    }()

    static func at(phase: Double, time: Double? = nil) -> TourFrame {
        let wrapped = phase - phase.rounded(.down)
        let clock = time ?? wrapped * TourFrame.cycle
        let utterance = clock - (clock / TourFrame.cycle).rounded(.down) * TourFrame.cycle
        let spoken = Self.words.enumerated()
            .filter { SpeechSchedule.finished($0.offset) <= utterance }
            .map(\.element)
        return TourFrame(
            phase: wrapped,
            level: SpeechSchedule.level(at: utterance),
            pulse: (utterance * 2).truncatingRemainder(dividingBy: 1),
            time: utterance,
            spoken: spoken
        )
    }

    static var cycle: Double { SpeechSchedule.spoken + 2.2 }
    static var stillPhase: Double { max(0, SpeechSchedule.spoken - 0.12) / cycle }

    var typed: String {
        guard !spoken.isEmpty else { return "" }
        return spoken.map(\.text).joined(separator: " ")
    }
}

// MARK: - Timing helpers

private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
private func ease(_ x: Double) -> Double { let c = clamp01(x); return c * c * (3 - 2 * c) }
/// 0 → 1 between `a` and `b`.
private func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double { ease((t - a) / (b - a)) }

// MARK: - Pieces

private struct TourIsland<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(width: 380, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(white: 0.10), Color(white: 0.04)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.28), radius: 20, y: 10)
    }
}

/// Bars that follow the demonstration voice at `speech` seconds.
private struct TourWave: View {
    let speech: Double
    var count = 28

    var body: some View {
        Canvas { context, size in
            let bw: CGFloat = 2.6
            let gap = (size.width - CGFloat(count) * bw) / CGFloat(count - 1)
            let mid = size.height / 2
            for i in 0..<count {
                let lag = Double(count - 1 - i) * 0.03
                let level = SpeechSchedule.level(at: speech - lag)
                let h = max(1.6, CGFloat(pow(level, 0.8)) * (mid - 1))
                let x = CGFloat(i) * (bw + gap)
                let path = Path(roundedRect: CGRect(x: x, y: mid - h, width: bw, height: h * 2), cornerRadius: bw / 2)
                let color = level > 0.55 ? HUDTheme.live : Color.white.opacity(0.35 + level * 0.6)
                context.fill(path, with: .color(color))
            }
        }
        .frame(height: 22)
    }
}

private struct RecordingRow: View {
    let speech: Double
    let elapsed: Double

    var body: some View {
        HStack(spacing: 12) {
            LiveDot(level: SpeechSchedule.level(at: speech), pulse: (elapsed * 1.5).truncatingRemainder(dividingBy: 1))
                .frame(width: HUDTheme.dotDiameter, height: HUDTheme.dotDiameter)
            TourWave(speech: speech)
            Text(HUDClock.string(for: max(0, elapsed)))
                .font(HUDTheme.clockFont)
                .foregroundStyle(Color.white.opacity(0.75))
                .monospacedDigit()
        }
    }
}

private struct TourKeys: View {
    let shortcut: String
    let pressed: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { index, symbol in
                TourKeycap(symbol: symbol, index: index, pressed: pressed)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(DotTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(
                            pressed ? DotTheme.amber.opacity(0.40) : DotTheme.cardBorder,
                            lineWidth: 1
                        )
                )
                .shadow(
                    color: pressed ? DotTheme.amber.opacity(0.18) : DotTheme.cardShadow,
                    radius: pressed ? 10 : 6,
                    x: 0,
                    y: pressed ? 2 : 4
                )
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: pressed)
    }

    private var symbols: [String] {
        let parts = shortcut.filter { !$0.isWhitespace && $0 != "+" && $0 != "\u{200A}" && $0 != "\u{200B}" }
            .map(String.init)
        return parts.isEmpty ? ["⌥", "⌘", "D"] : parts
    }
}

private struct TourKeycap: View {
    let symbol: String
    let index: Int
    let pressed: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.18))
                .frame(width: 44, height: 44)
                .offset(y: 2.5)

            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(pressed ? DotTheme.sidebarSelectedFill : DotTheme.raisedFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            pressed ? DotTheme.amber.opacity(0.90) : DotTheme.cardBorder,
                            lineWidth: pressed ? 1.5 : 1
                        )
                )
                .shadow(
                    color: pressed ? DotTheme.amber.opacity(0.35) : Color.black.opacity(0.12),
                    radius: pressed ? 2 : 2.5,
                    x: 0,
                    y: pressed ? 0.5 : 2
                )
                .frame(width: 44, height: 44)
                .offset(y: pressed ? 2.0 : 0)

            Text(symbol)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(pressed ? DotTheme.amber : DotTheme.ink)
                .frame(width: 44, height: 44, alignment: .center)
                .offset(y: pressed ? 2.0 : 0)
        }
        .frame(width: 44, height: 47, alignment: .center)
        .animation(
            .spring(response: 0.22, dampingFraction: 0.60).delay(Double(index) * 0.025),
            value: pressed
        )
    }
}

// MARK: - Scenes

private struct HoldScene: View {
    let t: Double
    let shortcut: String
    private let pressStart = 0.8
    private let pressEnd = 2.2

    var body: some View {
        let isPressed = t >= pressStart && t < pressEnd
        let appear = ramp(t, 1.3, 1.9)
        let leave = ramp(t, 6.6, 7.3)
        let shown = appear * (1 - leave)
        let started = 1.7

        VStack(spacing: 24) {
            TourIsland {
                RecordingRow(
                    speech: max(0, t - started) * 0.45,
                    elapsed: max(0, t - started)
                )
            }
            .scaleEffect(0.88 + 0.12 * shown, anchor: .top)
            .opacity(shown)
            .offset(y: -12 * (1 - shown))

            TourKeys(shortcut: shortcut, pressed: isPressed)
        }
    }
}

private struct SpeakScene: View {
    let t: Double

    private let waitDuration = 1.6
    private let fullSentenceTime = 5.2

    var body: some View {
        let enterRamp = ramp(t, 0.0, 0.6)
        let activeTime = max(0, t - waitDuration)
        let isSpeaking = t >= waitDuration

        let typeProgress = ramp(t, waitDuration, fullSentenceTime)
        let charCount = Int(Double(TourFrame.sentence.count) * typeProgress)
        let currentText = isSpeaking ? String(TourFrame.sentence.prefix(charCount)) : ""
        let isTyping = isSpeaking && typeProgress < 1.0

        let speechEnergy = isSpeaking && isTyping ? activeTime * 0.55 : 0.0
        let elapsedCounter = min(3.0, activeTime)

        TourIsland {
            VStack(alignment: .leading, spacing: 11) {
                RecordingRow(
                    speech: speechEnergy,
                    elapsed: elapsedCounter
                )
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                HStack(spacing: 0) {
                    if !currentText.isEmpty {
                        Text(currentText)
                            .font(.system(size: 14.5, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.95))
                            .lineLimit(1)
                    } else {
                        Text("Listening…")
                            .font(.system(size: 14.5, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.35))
                            .lineLimit(1)
                    }
                    Rectangle()
                        .fill(HUDTheme.live)
                        .frame(width: 2, height: 16)
                        .opacity((t * 2).truncatingRemainder(dividingBy: 1) < 0.6 ? 1 : 0)
                        .padding(.leading, 2)
                    Spacer(minLength: 0)
                }
            }
        }
        .scaleEffect(0.92 + 0.08 * enterRamp)
        .opacity(enterRamp)
        .offset(y: -8 * (1 - enterRamp))
    }
}

private struct PasteScene: View {
    let t: Double
    let shortcut: String

    private let pressStart = 1.4
    private let pressEnd = 2.2
    private let transcribeStart = 2.2
    private let pasteStart = 4.2
    private let islandFadeOut = 7.4

    var body: some View {
        let isPressed = t >= pressStart && t < pressEnd
        let isTranscribing = t >= transcribeStart && t < pasteStart
        let isPasted = t >= pasteStart
        let islandOut = ramp(t, islandFadeOut, 8.0)

        let typeProgress = ramp(t, pasteStart, pasteStart + 1.2)
        let charCount = Int(Double(TourFrame.sentence.count) * typeProgress)
        let typedText = String(TourFrame.sentence.prefix(charCount))
        let isTyping = isPasted && typeProgress < 1.0

        VStack(spacing: 16) {
            TourIsland {
                if isPasted {
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(HUDTheme.mint)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(HUDTheme.mint.opacity(0.20)))
                        Text("PASTED")
                            .font(HUDTheme.labelFont)
                            .tracking(HUDTheme.labelTracking)
                            .foregroundStyle(HUDTheme.mint)
                        Spacer()
                        Text("00:03")
                            .font(HUDTheme.clockFont)
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                    .frame(height: 22)
                } else if isTranscribing {
                    HStack(spacing: 10) {
                        HUDSpinner(phase: (t - transcribeStart) * 1.6)
                        Text("TRANSCRIBING…")
                            .font(HUDTheme.labelFont)
                            .tracking(HUDTheme.labelTracking)
                            .foregroundStyle(Color.white.opacity(0.92))
                        Spacer()
                        Text("00:03")
                            .font(HUDTheme.clockFont)
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                    .frame(height: 22)
                } else {
                    RecordingRow(speech: min(1.4, t) * 0.45, elapsed: min(3.0, t + 1.6))
                }
            }
            .opacity(1 - islandOut)

            // The document the cursor is in
            HStack(spacing: 0) {
                if !typedText.isEmpty {
                    Text(typedText)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(DotTheme.ink)
                }
                Rectangle()
                    .fill(DotTheme.ink)
                    .frame(width: 1.5, height: 17)
                    .opacity(isTyping ? 1.0 : ((t * 1.8).truncatingRemainder(dividingBy: 1) < 0.55 ? 1 : 0))
                    .padding(.leading, typedText.isEmpty ? 0 : 2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(width: 380, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DotTheme.raisedFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(DotTheme.cardBorder, lineWidth: 1)
                    )
            )
            .shadow(color: DotTheme.cardShadow, radius: 8, y: 3)

            TourKeys(shortcut: shortcut, pressed: isPressed)
        }
    }
}

private struct TourScene: View {
    let step: TourStep
    let shortcut: String
    var animated = true
    var phase: Double? = nil

    @State private var startTime = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if animated && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                    let elapsed = max(0, context.date.timeIntervalSince(startTime))
                    scene(at: elapsed.truncatingRemainder(dividingBy: step.cycle))
                }
            } else {
                let time = phase.map { $0 * step.cycle } ?? step.stillTime
                scene(at: time)
            }
        }
        .frame(height: 230)
        .accessibilityHidden(true)
        .onAppear {
            startTime = Date()
        }
        .onChange(of: step) { _, _ in
            startTime = Date()
        }
    }

    @ViewBuilder
    private func scene(at t: Double) -> some View {
        switch step {
        case .hold: HoldScene(t: t, shortcut: shortcut)
        case .speak: SpeakScene(t: t)
        case .paste: PasteScene(t: t, shortcut: shortcut)
        }
    }
}

// MARK: - Page

struct WelcomeTourPage: View {
    let step: TourStep
    let shortcutLabel: String
    /// How the recorded shortcut starts and ends a recording, so the tour
    /// teaches the interaction the person is actually going to get.
    var recordingMode: RecordingMode = .toggle
    var animated = true
    var phase: Double = TourFrame.stillPhase
    let onBack: () -> Void
    let onNext: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)

            TourScene(step: step, shortcut: shortcutLabel, animated: animated, phase: animated ? nil : phase)
                .id(step)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 8)),
                    removal: .opacity
                ))

            VStack(spacing: 8) {
                Text(step.title(shortcut: shortcutLabel, mode: recordingMode))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(DotTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(step.detail(mode: recordingMode))
                    .font(.system(size: 13.5))
                    .foregroundStyle(DotTheme.ink2)
            }
            .padding(.top, 36)
            .id("text-\(step.rawValue)")
            .transition(.opacity)

            Spacer(minLength: 24)

            HStack {
                Button("Skip") { onSkip() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DotTheme.ink3)
                    .frame(width: 170, alignment: .leading)

                Spacer()

                HStack(spacing: 6) {
                    ForEach(TourStep.allCases) { each in
                        Capsule()
                            .fill(each == step ? DotTheme.selectionFill : DotTheme.ink3.opacity(0.28))
                            .frame(width: each == step ? 18 : 6, height: 6)
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: step)
                .accessibilityHidden(true)

                Spacer()

                HStack(spacing: 8) {
                    if step != .hold {
                        Button("Back") { onBack() }
                            .buttonStyle(DotSecondaryButtonStyle())
                    }
                    Button(step == .paste ? "Continue" : "Next") { onNext() }
                        .buttonStyle(DotPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
                .frame(width: 170, alignment: .trailing)
            }
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 26)
    }
}
