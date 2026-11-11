import AppKit
import DotCore
import SwiftUI

/// The Connectors page: which apps the assistant may use, what each one needs
/// before it can be used, and what a change must do first.
///
/// Every row comes from a ``ConnectorSummary``, so a connector added to the
/// catalogue appears here without the page changing, and a permission macOS
/// reports is shown as the words a person uses for it.
@MainActor
struct ConnectorsPage: View {
    @Binding var config: DotConfig
    let onChange: () -> Void

    @Environment(\.settingsConnectorSummaries) private var previewSummaries

    @State private var loaded: [ConnectorSummary] = []
    @State private var registry: ConnectorRegistry?

    private var summaries: [ConnectorSummary] {
        previewSummaries ?? loaded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            connectedAppsSection
            changesSection
        }
        .task { await loadSummaries() }
    }

    // MARK: - Connected apps

    private var connectedAppsSection: some View {
        SettingsSection("Connected apps") {
            ForEach(Array(summaries.enumerated()), id: \.offset) { index, summary in
                if index > 0 {
                    SettingsDivider()
                }
                connectorRow(summary)
            }
        }
    }

    private func connectorRow(_ summary: ConnectorSummary) -> some View {
        SettingsRow(
            summary.displayName,
            subtitle: permissionWords(summary.permission.status),
            symbol: summary.symbol
        ) {
            HStack(spacing: 8) {
                if summary.permission.status != .granted {
                    let asks = summary.permission.status == .notDetermined
                    Button(asks ? "Grant access" : "Open Settings") {
                        grantAccess(summary)
                    }
                    .buttonStyle(DotSecondaryButtonStyle())
                    .accessibilityLabel(asks
                        ? "Grant access to \(summary.displayName)"
                        : "Open the privacy settings for \(summary.displayName)")
                }
                Toggle("", isOn: enabledBinding(summary.id))
                    .labelsHidden()
                    .toggleStyle(DotToggleStyle())
                    .accessibilityLabel(summary.displayName)
            }
        }
    }

    /// The permission in the words a person uses for it.
    private func permissionWords(_ status: ConnectorPermissionStatus) -> String {
        switch status {
        case .granted: "Ready"
        case .notDetermined: "Needs access"
        case .denied, .restricted: "Access denied"
        }
    }

    /// Asks for access, or opens the switch when macOS will not ask again.
    private func grantAccess(_ summary: ConnectorSummary) {
        if summary.permission.status != .notDetermined,
           let url = summary.permission.settingsURL {
            NSWorkspace.shared.open(url)
            return
        }
        Task {
            _ = await registry?.requestAccess(summary.id)
            await loadSummaries()
        }
    }

    private func enabledBinding(_ id: ConnectorID) -> Binding<Bool> {
        Binding(
            get: { config.assistant.connectors.isEnabled(id) },
            set: { value in
                guard config.assistant.connectors.isEnabled(id) != value else { return }
                config.assistant.connectors.setEnabled(value, for: id)
                onChange()
                updateRegistry()
            }
        )
    }

    // MARK: - Changes

    private var changesSection: some View {
        SettingsSection("Changes") {
            SettingsRow("Before an app changes something", subtitle: "Deleting and sending always ask.") {
                DotSelect(
                    label: "Before an app changes something",
                    options: ChangesChoice.allCases.map { choice in
                        DotSelectOption(value: choice, title: choice.title)
                    },
                    selection: changesBinding,
                    width: 220
                )
            }
        }
    }

    /// What a write tool does before it runs.
    ///
    /// A destructive or sending tool is not part of this choice: the policy
    /// table holds it at "ask" whatever is stored, so the page can promise that
    /// deleting and sending always ask.
    private enum ChangesChoice: String, CaseIterable {
        case ask
        case allow

        var title: String {
            switch self {
            case .ask: "Ask me first"
            case .allow: "Just do it"
            }
        }
    }

    private var changesChoice: ChangesChoice {
        let writes = summaries.flatMap(\.tools).filter { $0.risk == .write }
        guard !writes.isEmpty else {
            return config.assistant.connectors.policies.values.contains(.allow) ? .allow : .ask
        }
        return writes.allSatisfy { $0.policy == .allow } ? .allow : .ask
    }

    private var changesBinding: Binding<ChangesChoice> {
        Binding(
            get: { changesChoice },
            set: { choice in
                guard choice != changesChoice else { return }
                apply(choice)
            }
        )
    }

    private func apply(_ choice: ChangesChoice) {
        var settings = config.assistant.connectors
        for summary in summaries {
            for tool in summary.tools where tool.risk == .write {
                settings.policies[tool.name] = choice == .allow ? .allow : nil
            }
        }
        config.assistant.connectors = settings
        onChange()
        updateRegistry()
    }

    // MARK: - Loading

    private func loadSummaries() async {
        guard previewSummaries == nil else { return }
        let registry: ConnectorRegistry
        if let existing = self.registry {
            registry = existing
        } else {
            let made = ConnectorCatalog.registry(
                settings: config.assistant.connectors,
                gate: .denyAll,
                log: .silent
            )
            self.registry = made
            registry = made
        }
        await registry.update(config.assistant.connectors)
        let fresh = await registry.summaries()
        guard !Task.isCancelled else { return }
        loaded = fresh
    }

    /// Keeps the registry this page asked for in step with the switches, so a
    /// permission prompt answers the page and not a copy of yesterday's file.
    private func updateRegistry() {
        guard let registry else { return }
        let settings = config.assistant.connectors
        Task { await registry.update(settings) }
    }
}
