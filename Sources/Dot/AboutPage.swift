import AppKit
import DotCore
import SwiftUI

// MARK: - This build

/// What the About page says about the build it is drawn in.
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

    /// The build as the page writes it after the version.
    static func versionLine(version: String, build: String?) -> String {
        "Version \(valueLine(version: version, build: build))"
    }

    /// The colophon's value: the version alone when there is no build to name.
    static func valueLine(version: String, build: String?) -> String {
        guard let build, !build.isEmpty, build != ProductVersion.unknown else {
            return version
        }
        return "\(version) (\(build))"
    }
}

/// What the update control is showing.
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

    /// The control's name, which changes once a release exists to open.
    var controlLabel: String {
        switch self {
        case .available: "View release"
        case .idle, .checking, .upToDate, .unreachable: "Check for updates"
        }
    }

    /// The line under the control, set in words rather than in colour alone.
    var statusText: String {
        switch self {
        case .idle: "Not checked"
        case .checking: "Checking..."
        case .upToDate: "Up to date"
        case .available(let version, _): "Version \(version) available"
        case .unreachable: "Could not reach GitHub"
        }
    }

    /// A check already in flight owns the control until it answers.
    var acceptsAnotherCheck: Bool { self != .checking }
}

/// The frames a headless host reads back from the page.
///
/// The renderer draws these views off screen, where AppKit exposes no
/// accessibility tree for a SwiftUI button. A geometry reader in each named
/// region reports its own frame instead, so the plate and its contents are
/// measured where they are laid out rather than guessed from a picture.
struct AboutLayoutSnapshot: Equatable {
    var frames: [String: CGRect] = [:]
}

private struct AboutFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct AboutLayoutReportingKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var aboutLayoutReporting: Bool {
        get { self[AboutLayoutReportingKey.self] }
        set { self[AboutLayoutReportingKey.self] = newValue }
    }
}

private struct AboutFrameReporter: ViewModifier {
    @Environment(\.aboutLayoutReporting) private var reports

    let name: String

    func body(content: Content) -> some View {
        if reports {
            content.background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: AboutFrameKey.self,
                        value: [name: geometry.frame(in: .named(AboutPage.layoutSpace))]
                    )
                }
            }
        } else {
            content
        }
    }
}

private extension View {
    func aboutFrame(_ name: String) -> some View {
        modifier(AboutFrameReporter(name: name))
    }
}

// MARK: - The page

/// The About page inside Settings.
///
/// Dot has one About surface. It is this page: the name and the build, the one
/// place the update check can be run from, and the places Dot lives. The menu
/// bar's About Dot opens Settings here rather than a second window that would
/// have to be kept in step with this one.
@MainActor
struct AboutPage: View {
    /// The version to show, exactly as the bundle declares it.
    let version: String
    /// The build number, or `nil` outside a bundle that declares one.
    var build: String?
    /// A state to draw instead of asking GitHub. Renders pass one.
    var previewUpdate: AboutUpdateState?
    /// Opens the welcome window.
    var onOpenWelcome: () -> Void = {}
    /// Reveals the log file in Finder.
    var onOpenLog: () -> Void = {}
    /// Counts a press made in a preview, where no request may be sent.
    var onPreviewUpdatePress: (() -> Void)?
    /// Reads the laid-out frames in a headless host.
    var onLayout: ((AboutLayoutSnapshot) -> Void)?

    @State private var copied = false
    @State private var update: AboutUpdateState = .idle
    @State private var copyReset: Task<Void, Never>?

    /// The coordinate space every reported frame is measured in.
    static let layoutSpace = "AboutPage.content"
    /// The mark is drawn from the approved icon geometry on an imaginary 100 pt
    /// square pinned to the plate's top right corner.
    private static let markSquare: CGFloat = 100
    private static let markDiameter: CGFloat = markSquare * DotMarkDial.clipped.diameter
    private static let markRightInset: CGFloat = markSquare * (1 - DotMarkDial.clipped.centre.x)
    private static let markTopInset: CGFloat = markSquare * DotMarkDial.clipped.centre.y
    /// The trailing room the control leaves for the cropped disc.
    private static let markReserve: CGFloat = 72

    var body: some View {
        VStack(spacing: 14) {
            plate
            destinations
            actions
        }
        .frame(maxWidth: .infinity)
        .environment(\.aboutLayoutReporting, onLayout != nil)
        .coordinateSpace(name: Self.layoutSpace)
        .onPreferenceChange(AboutFrameKey.self) { frames in
            onLayout?(AboutLayoutSnapshot(frames: frames))
        }
    }

    // MARK: Dial plate

    /// The matte plate carries the name, the update control and the colophon.
    ///
    /// The disc is one drawing inside the plate's single clip. Nothing else on
    /// the page draws a mark, a shadow or a second edge.
    private var plate: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                upperBand
                Rectangle()
                    .fill(AboutDialInk.edge)
                    .frame(height: 1)
                    .aboutFrame("rule")
                colophon
            }
            mark
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DotTheme.cardCorner, style: .continuous)
                .fill(AboutDialInk.plate)
        )
        .clipShape(
            RoundedRectangle(cornerRadius: DotTheme.cardCorner, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DotTheme.cardCorner, style: .continuous)
                .strokeBorder(AboutDialInk.edge, lineWidth: 1)
        )
        .aboutFrame("plate")
    }

    /// The white disc, cut by the plate and kept out of hit testing and the
    /// accessibility tree.
    private var mark: some View {
        GeometryReader { geometry in
            ZStack {
                if onLayout != nil {
                    Color.clear
                        .preference(
                            key: AboutFrameKey.self,
                            value: ["disc": discFrame(in: geometry)]
                        )
                }
                Circle()
                    .fill(AboutDialInk.disc)
                    .frame(width: Self.markDiameter, height: Self.markDiameter)
                    .position(
                        x: geometry.size.width - Self.markRightInset,
                        y: Self.markTopInset
                    )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func discFrame(in geometry: GeometryProxy) -> CGRect {
        let plate = geometry.frame(in: .named(Self.layoutSpace))
        return CGRect(
            x: plate.minX + geometry.size.width - Self.markRightInset - Self.markDiameter / 2,
            y: plate.minY + Self.markTopInset - Self.markDiameter / 2,
            width: Self.markDiameter,
            height: Self.markDiameter
        )
    }

    private var upperBand: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Dot")
                .font(DotTheme.displayFont(30))
                .tracking(-0.4)
                .foregroundStyle(AboutDialInk.value)
                .accessibilityAddTraits(.isHeader)
                .aboutFrame("title")

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 2) {
                Button(action: performUpdate) {
                    Text(currentUpdate.controlLabel)
                        .font(DotType.font(12, .semibold))
                        .foregroundStyle(
                            currentUpdate.acceptsAnotherCheck ? AboutDialInk.value : AboutDialInk.status
                        )
                        .frame(minHeight: 28)
                        .padding(.horizontal, 12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(
                                    AboutDialInk.buttonEdge.opacity(currentUpdate.acceptsAnotherCheck ? 1 : 0.5),
                                    lineWidth: 1
                                )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(DotPressStyle())
                .disabled(!currentUpdate.acceptsAnotherCheck)
                .accessibilityLabel(currentUpdate.controlLabel)
                .accessibilityValue(currentUpdate.statusText)
                .aboutFrame("control")

                Text(currentUpdate.statusText)
                    .font(DotType.font(11, .medium))
                    .foregroundStyle(AboutDialInk.status)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
                    .accessibilityHidden(true)
                    .aboutFrame("status")
            }
            .padding(.trailing, Self.markReserve)
        }
        .frame(minHeight: 72, alignment: .center)
        .padding(.horizontal, 16)
        .aboutFrame("upper")
    }

    private var colophon: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Version")
                    .font(DotType.font(11, .medium))
                    .foregroundStyle(AboutDialInk.status)
                    .aboutFrame("versionLabel")
                HStack(spacing: 6) {
                    Text(AboutInfo.valueLine(version: version, build: build))
                        .font(DotType.tabularFont(12, .medium))
                        .foregroundStyle(AboutDialInk.value)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .aboutFrame("versionValue")
                    copyButton
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .aboutFrame("versionCell")

            Rectangle()
                .fill(AboutDialInk.edge)
                .frame(width: 1)
                .aboutFrame("separator")

            VStack(alignment: .leading, spacing: 3) {
                Text("macOS")
                    .font(DotType.font(11, .medium))
                    .foregroundStyle(AboutDialInk.status)
                    .aboutFrame("systemLabel")
                Text(AboutInfo.operatingSystem)
                    .font(DotType.tabularFont(12, .medium))
                    .foregroundStyle(AboutDialInk.value)
                    .fixedSize(horizontal: false, vertical: true)
                    .aboutFrame("systemValue")
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .aboutFrame("systemCell")
        }
        .frame(minHeight: 44, alignment: .center)
        .aboutFrame("lower")
    }

    private var copyButton: some View {
        Button(action: copyVersion) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(DotType.font(11, .semibold))
                .foregroundStyle(copied ? AboutDialInk.value : AboutDialInk.status)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(DotPressStyle())
        .accessibilityLabel("Copy version information")
        .accessibilityValue(copied ? "Copied" : "")
        .help("Copies the version, the build and the macOS version.")
        .aboutFrame("copy")
    }

    private func copyVersion() {
        let line = AboutInfo.copyLine(
            version: version,
            build: build ?? AboutInfo.build,
            macOS: AboutInfo.operatingSystem
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(line, forType: .string)

        copied = true
        copyReset?.cancel()
        copyReset = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    // MARK: Update control

    /// The state the control draws: the preview's when one was supplied,
    /// otherwise what the last check found.
    private var currentUpdate: AboutUpdateState {
        previewUpdate ?? update
    }

    /// Runs the update button's own action in a headless host, where AppKit
    /// exposes no accessibility press target for a SwiftUI button.
    func activateUpdateForTesting() {
        performUpdate()
    }

    private func performUpdate() {
        guard previewUpdate == nil else {
            onPreviewUpdatePress?()
            return
        }
        if case .available(_, let page) = currentUpdate {
            NSWorkspace.shared.open(page ?? ProductLinks.website)
            return
        }
        guard currentUpdate != .checking else { return }
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

    // MARK: Destinations

    /// The five places Dot lives, unchanged from the settings card rhythm.
    private var destinations: some View {
        DotCard {
            VStack(spacing: 0) {
                linkRow(
                    "Website",
                    detail: ProductLinks.displayWebsite,
                    symbol: "globe",
                    url: ProductLinks.website
                )
                SettingsDivider()
                linkRow(
                    "GitHub",
                    detail: ProductLinks.displayGitHub,
                    symbol: "chevron.left.forwardslash.chevron.right",
                    url: ProductLinks.github
                )
                SettingsDivider()
                linkRow(
                    "Report an issue",
                    detail: ProductLinks.displayIssues,
                    symbol: "exclamationmark.bubble",
                    url: ProductLinks.newIssue
                )
                SettingsDivider()
                linkRow(
                    "Support Dot",
                    detail: ProductLinks.displaySupport,
                    symbol: "cup.and.saucer",
                    url: ProductLinks.support
                )
                SettingsDivider()
                linkRow(
                    "Licence",
                    detail: ProductLinks.licenceName,
                    symbol: "doc.text",
                    url: ProductLinks.licence
                )
            }
        }
    }

    /// A row that leaves Dot for the browser.
    private func linkRow(_ title: String, detail: String?, symbol: String, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            SettingsRow(title, symbol: symbol) {
                HStack(spacing: 8) {
                    if let detail {
                        Text(detail)
                            .font(DotType.font(11, .medium))
                            .foregroundStyle(DotTheme.ink2)
                            .lineLimit(1)
                    }
                    Image(systemName: "arrow.up.right")
                        .font(DotType.font(10, .semibold))
                        .foregroundStyle(DotTheme.ink3)
                }
            }
        }
        .buttonStyle(DotPressStyle())
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
    }

    // MARK: Actions inside Dot

    /// The two rows that act on Dot itself rather than on the network.
    private var actions: some View {
        DotCard {
            VStack(spacing: 0) {
                Button(action: onOpenWelcome) {
                    SettingsRow("Show welcome tour", symbol: "sparkles") {
                        Image(systemName: "chevron.right")
                            .font(DotType.font(10, .semibold))
                            .foregroundStyle(DotTheme.ink3)
                    }
                }
                .buttonStyle(DotPressStyle())
                SettingsDivider()
                Button(action: onOpenLog) {
                    SettingsRow("Open log", symbol: "doc.text.magnifyingglass") {
                        Image(systemName: "chevron.right")
                            .font(DotType.font(10, .semibold))
                            .foregroundStyle(DotTheme.ink3)
                    }
                }
                .buttonStyle(DotPressStyle())
                .aboutFrame("openLog")
            }
        }
        .aboutFrame("actions")
    }
}

/// The plate's fixed colours, sampled from the approved composition.
///
/// These are fixed rather than adaptive: the dial is a picture of the app icon
/// and does not change with the system appearance.
enum AboutDialInk {
    static let plate = Color(.sRGB, red: 0x24 / 255, green: 0x21 / 255, blue: 0x1E / 255)
    static let edge = Color(.sRGB, red: 0x62 / 255, green: 0x57 / 255, blue: 0x4D / 255)
    static let disc = Color(.sRGB, red: 0xF4 / 255, green: 0xF2 / 255, blue: 0xEE / 255)
    static let value = Color(.sRGB, red: 0xFF / 255, green: 0xF4 / 255, blue: 0xE6 / 255)
    static let status = Color(.sRGB, red: 0xD8 / 255, green: 0xCA / 255, blue: 0xBC / 255)
    static let buttonEdge = Color(.sRGB, red: 0x9D / 255, green: 0x8C / 255, blue: 0x7D / 255)
}
