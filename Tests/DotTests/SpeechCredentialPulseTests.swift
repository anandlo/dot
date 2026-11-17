import AppKit
import SwiftUI
import XCTest

@testable import Dot

/// The dot beside the service picker, captured while a page checks, settles and
/// checks again.
///
/// The page stays on screen across many checks, so the pulse has to start on
/// every entry into checking and stop on every exit. A screenshot of one
/// moment cannot show that, so each state is sampled three times (at the start,
/// half a cycle and a whole cycle) from one hosting view whose status changes
/// underneath it, the way the page's does. The measure is the dot's opacity,
/// read from the pixels against the same dot drawn at full opacity.
///
/// The twelve PNGs and the table of measured opacities are written to
/// `DOT_PULSE_DIR` when it is set; the assertions run either way.
@MainActor
final class SpeechCredentialPulseTests: XCTestCase {
    /// Two pixels per point, like every other render.
    private static let scale = 2
    /// The label plus 10 points of padding on each side, on a white field.
    private static let size = CGSize(width: 144, height: 40)
    /// The moment a settled state says it was checked, so the frames are
    /// deterministic.
    private static let checkedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// Where the twelve PNGs and the opacity table are written.
    private static var evidence: URL? {
        guard let value = ProcessInfo.processInfo.environment["DOT_PULSE_DIR"],
              !value.isEmpty
        else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    // MARK: - The two appearances

    /// Leaving checking stops the loop; entering it starts a new one.
    ///
    /// The measured frames are the second checking state, after a settled one:
    /// that is the transition the old dot never pulsed on.
    func testTheDotPulsesOnTheCheckThatFollowsASettledAnswer() throws {
        let checkingReference = try opaqueReference(for: .checking)
        let verifiedReference = try opaqueReference(for: .settled(.verified, checkedAt: Self.checkedAt))

        let live = live(.checking, reduceMotion: false)
        defer { live.close() }
        // One pulse of the first check runs and is not measured.
        _ = try capture(live, after: 0.45)

        live.model.status = .settled(.verified, checkedAt: Self.checkedAt)
        let verified = try sample(
            live,
            state: "verified",
            mode: "off",
            reference: verifiedReference,
            times: [0.02, 0.62, 1.22]
        )

        live.model.status = .checking
        let checking = try sample(
            live,
            state: "checking",
            mode: "off",
            reference: checkingReference,
            times: [0.02, 0.62, 1.22]
        )

        for frame in verified {
            XCTAssertGreaterThanOrEqual(
                frame.opacity,
                0.98,
                "a settled answer kept the dot moving at \(frame.label)"
            )
        }
        let low = try XCTUnwrap(checking.map(\.opacity).min())
        let high = try XCTUnwrap(checking.map(\.opacity).max())
        XCTAssertLessThan(low, 0.75, "the dot did not pulse on the check after a settled answer: \(checking)")
        XCTAssertGreaterThan(high, 0.95, "the dot never reached full opacity while checking: \(checking)")
        XCTAssertGreaterThan(high - low, 0.3, "the dot moved too little to read as a pulse: \(checking)")
        report(verified + checking)
    }

    /// With Reduce Motion on, every state is one still, opaque dot.
    func testReducedMotionKeepsTheDotStillInEveryState() throws {
        let live = live(.checking, reduceMotion: true)
        defer { live.close() }

        let checking = try sample(
            live,
            state: "checking",
            mode: "on",
            reference: nil,
            times: [0.02, 0.62, 1.22]
        )
        live.model.status = .settled(.verified, checkedAt: Self.checkedAt)
        let verified = try sample(
            live,
            state: "verified",
            mode: "on",
            reference: nil,
            times: [0.02, 0.62, 1.22]
        )

        for frames in [checking, verified] {
            let first = try XCTUnwrap(frames.first)
            for frame in frames.dropFirst() {
                XCTAssertLessThanOrEqual(
                    frame.channelDelta(from: first),
                    2,
                    "the dot moved under Reduce Motion at \(frame.label)"
                )
            }
        }
        report(checking + verified)
    }

    // MARK: - The live view

    /// One status the hosting view reads, so a state can change without the
    /// view being rebuilt. A rebuild would restart the pulse by itself and hide
    /// exactly the defect this test exists for.
    private final class Model: ObservableObject {
        @Published var status: SpeechCredentialStatus

        init(_ status: SpeechCredentialStatus) {
            self.status = status
        }
    }

    private struct HostView: View {
        @ObservedObject var model: Model
        let reduceMotion: Bool

        var body: some View {
            SpeechCredentialLabel(status: model.status, reduceMotionOverride: reduceMotion)
                .padding(10)
                .frame(width: 144, height: 40)
                .background(Color.white)
        }
    }

    private struct Live {
        let model: Model
        let host: NSHostingView<AnyView>
        let window: OffscreenWindow

        @MainActor func close() {
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    private func live(_ status: SpeechCredentialStatus, reduceMotion: Bool) -> Live {
        _ = NSApplication.shared
        let model = Model(status)
        let host = NSHostingView(rootView: AnyView(HostView(model: model, reduceMotion: reduceMotion)))
        host.frame = NSRect(origin: .zero, size: Self.size)
        let window = OffscreenWindow(size: Self.size, styleMask: [.borderless])
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return Live(model: model, host: host, window: window)
    }

    /// The same dot at full opacity, which the measured frames are read
    /// against. It is drawn through the same path, so the colour management of
    /// the display and the anti-aliasing of the circle cancel out.
    private func opaqueReference(for status: SpeechCredentialStatus) throws -> Sample {
        let reference = live(status, reduceMotion: true)
        defer { reference.close() }
        return try capture(reference, after: 0.1)
    }

    // MARK: - Frames

    /// One measured frame: the dot's colour, where it was found, and what its
    /// opacity came out as.
    private struct Sample {
        let red: Double
        let green: Double
        let blue: Double
        let x: Int
        let y: Int
        let opacity: Double
        let time: Double
        let mode: String
        let state: String
        let label: String

        /// The largest per-channel difference from another sample.
        func channelDelta(from other: Sample) -> Double {
            max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue))
        }
    }

    /// Captures the state at each offset, measures the dot and writes a PNG.
    ///
    /// - Parameters:
    ///   - live: the hosted label.
    ///   - state: the state name used in the file and the table.
    ///   - mode: `off` or `on` for Reduce Motion.
    ///   - reference: the full-opacity dot, or `nil` for the first frame of
    ///     this set (the Reduce Motion case, where every frame is the same).
    ///   - times: the offsets in seconds, measured from the first capture.
    /// - Returns: the measured frames.
    private func sample(
        _ live: Live,
        state: String,
        mode: String,
        reference: Sample?,
        times: [Double]
    ) throws -> [Sample] {
        var frames: [Sample] = []
        var previous = 0.0
        let start = ProcessInfo.processInfo.systemUptime
        for target in times {
            let frame = try capture(live, after: target - previous, named: "\(state)-\(mode)-\(label(target))")
            previous = target
            let base = reference ?? frames.first ?? frame
            frames.append(Sample(
                red: frame.red,
                green: frame.green,
                blue: frame.blue,
                x: frame.x,
                y: frame.y,
                opacity: opacity(of: frame, over: base),
                time: ProcessInfo.processInfo.systemUptime - start,
                mode: mode,
                state: state,
                label: "\(state) \(mode) \(label(target))"
            ))
        }
        return frames
    }

    /// Runs the loop for `delay` and captures the hosting view at two pixels per
    /// point.
    private func capture(_ live: Live, after delay: TimeInterval, named name: String? = nil) throws -> Sample {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, delay)
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            guard now < deadline else { break }
            RunLoop.current.run(until: Date().addingTimeInterval(min(0.016, deadline - now)))
            live.host.layoutSubtreeIfNeeded()
            live.window.displayIfNeeded()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        live.host.layoutSubtreeIfNeeded()
        live.window.displayIfNeeded()

        let bitmap = try XCTUnwrap(cachedBitmap(live), "the frame could not be allocated")
        if let name, let directory = Self.evidence {
            try write(bitmap, named: "\(name).png", to: directory)
        }
        let dot = try XCTUnwrap(findDot(in: bitmap), "the dot was not drawn")
        return Sample(
            red: dot.red,
            green: dot.green,
            blue: dot.blue,
            x: dot.x,
            y: dot.y,
            opacity: 1,
            time: ProcessInfo.processInfo.systemUptime,
            mode: "",
            state: "",
            label: name ?? "frame"
        )
    }

    private func cachedBitmap(_ live: Live) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(Self.size.width) * Self.scale,
            pixelsHigh: Int(Self.size.height) * Self.scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = Self.size
        live.host.cacheDisplay(in: NSRect(origin: .zero, size: Self.size), to: bitmap)
        return bitmap
    }

    /// The dot's colour, taken from the most saturated pixel left of the text.
    ///
    /// The label starts with the dot: 10 points of padding, 6 points of circle,
    /// 6 points of spacing, then the word. The scan stops before the word, and
    /// the greatest distance from the white field is the middle of the circle.
    private func findDot(in bitmap: NSBitmapImageRep) -> (red: Double, green: Double, blue: Double, x: Int, y: Int)? {
        guard let data = bitmap.bitmapData, bitmap.samplesPerPixel == 4 else { return nil }
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let rowBytes = bitmap.bytesPerRow
        let limit = min(20 * Self.scale, width)
        var best: (red: Double, green: Double, blue: Double, x: Int, y: Int)?
        var bestDistance = -1.0
        for y in 0 ..< height {
            for x in 0 ..< limit {
                let index = y * rowBytes + x * 4
                let red = Double(data[index])
                let green = Double(data[index + 1])
                let blue = Double(data[index + 2])
                let distance = (255 - red) + (255 - green) + (255 - blue)
                if distance > bestDistance {
                    bestDistance = distance
                    best = (red, green, blue, x, y)
                }
            }
        }
        return best
    }

    /// The dot's opacity, against the same dot drawn at full opacity over white.
    private func opacity(of sample: Sample, over reference: Sample) -> Double {
        var values: [Double] = []
        for (measured, full) in [
            (sample.red, reference.red),
            (sample.green, reference.green),
            (sample.blue, reference.blue),
        ] {
            let denominator = 255 - full
            guard abs(denominator) > 1 else { continue }
            values.append(min(1, max(0, (255 - measured) / denominator)))
        }
        guard !values.isEmpty else { return 1 }
        return values.reduce(0, +) / Double(values.count)
    }

    // MARK: - Evidence

    private func label(_ time: Double) -> String {
        String(format: "%.1f", time)
    }

    private func report(_ samples: [Sample]) {
        for sample in samples {
            print(String(
                format: "pulse %@ t=%.2fs opacity=%.2f at (%d,%d)",
                sample.label,
                sample.time,
                sample.opacity,
                sample.x,
                sample.y
            ))
        }
        guard let directory = Self.evidence else { return }
        let lines = samples.map {
            String(format: "%@ t=%.2f opacity=%.2f", $0.label, $0.time, $0.opacity)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = "mode state t opacity\n" + lines.joined(separator: "\n") + "\n"
        try? Data(text.utf8).write(
            to: directory.appendingPathComponent("opacities-\(samples.first?.mode ?? "off").txt"),
            options: .atomic
        )
    }

    private func write(_ bitmap: NSBitmapImageRep, named name: String, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
