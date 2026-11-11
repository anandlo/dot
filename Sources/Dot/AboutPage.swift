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
        guard let build, !build.isEmpty, build != ProductVersion.unknown else {
            return "Version \(version)"
        }
        return "Version \(version) (\(build))"
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

    @State private var copied = false
    @State private var update: AboutUpdateState = .idle

    var body: some View {
        VStack(spacing: 22) {
            header
            destinations
            actions
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Header

    /// The mark, the name and the build, centred on the page.
    private var header: some View {
        VStack(spacing: 8) {
            DotMarkDialPresentation(dial: DotMark.chosenDial ?? .clipped, size: 64)
                .overlay(
                    DotSquircle()
                        .stroke(DotTheme.markEdge, lineWidth: 1)
                        .padding(64 * DotIconPresentation.paddingRatio)
                )
                .accessibilityHidden(true)

            Text("Dot")
                .font(DotTheme.displayFont(26))
                .tracking(-0.4)
                .foregroundStyle(DotTheme.ink)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 6) {
                Text(AboutInfo.versionLine(version: version, build: build))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(DotTheme.ink3)
                    .textSelection(.enabled)

                Button(action: copyVersion) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(copied ? DotTheme.ink2 : DotTheme.ink3)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy version information")
                .accessibilityValue(copied ? "Copied" : "")
                .help("Copies the version, the build and the macOS version.")
            }
        }
        .padding(.top, 6)
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

    // MARK: Destinations

    /// The update check and the places Dot lives.
    private var destinations: some View {
        DotCard {
            VStack(spacing: 0) {
                updateRow
                SettingsDivider()
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
                            .font(.system(size: 11))
                            .foregroundStyle(DotTheme.ink3)
                            .lineLimit(1)
                    }
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DotTheme.ink3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
    }

    /// The one control in the app that runs an update check outside the menu.
    private var updateRow: some View {
        Button(action: performUpdate) {
            SettingsRow("Check for updates", symbol: "arrow.triangle.2.circlepath") {
                Text(updateStatusText)
                    .font(.system(size: 11))
                    .foregroundStyle(DotTheme.ink3)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Check for updates")
        .accessibilityValue(updateStatusText)
    }

    /// The state the row draws: the preview's when one was supplied, otherwise
    /// what the last check found.
    private var currentUpdate: AboutUpdateState {
        previewUpdate ?? update
    }

    private var updateStatusText: String {
        switch currentUpdate {
        case .idle: return "Not checked"
        case .checking: return "Checking..."
        case .upToDate: return "Up to date"
        case .available(let version, _): return "Version \(version) available"
        case .unreachable: return "Could not reach GitHub"
        }
    }

    private func performUpdate() {
        guard previewUpdate == nil else { return }
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

    // MARK: Actions inside Dot

    /// The two rows that act on Dot itself rather than on the network.
    private var actions: some View {
        DotCard {
            VStack(spacing: 0) {
                Button(action: onOpenWelcome) {
                    SettingsRow("Show welcome tour", symbol: "sparkles") {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DotTheme.ink3)
                    }
                }
                .buttonStyle(.plain)
                SettingsDivider()
                Button(action: onOpenLog) {
                    SettingsRow("Open log", symbol: "doc.text.magnifyingglass") {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DotTheme.ink3)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
