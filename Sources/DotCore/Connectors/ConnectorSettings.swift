import Foundation

/// What a person chose on the Connectors page.
///
/// Two facts per install: which connectors the assistant may use at all, and
/// any per-tool policy that differs from the risk default. Both decode
/// tolerantly, because this lives inside a hand-editable JSON file and one bad
/// value must not reset the rest of the page.
public struct ConnectorSettings: Codable, Sendable, Equatable {
    /// The connectors that are switched on.
    ///
    /// The order is the order the person switched them on; the settings page
    /// reads its own order from ``ConnectorID/builtIn``.
    public var enabled: [ConnectorID]
    /// Per-tool overrides, keyed by tool name such as `reminders_create`.
    ///
    /// A pre-release build wrote these keys with a dot (`reminders.create`).
    /// The decoder reads that spelling as the underscore one, so a file from
    /// that build keeps its overrides instead of silently losing them.
    public var policies: [String: ToolPolicy]

    /// The connectors that work without a permission prompt, shipped on.
    ///
    /// Files and apps only read and open; system volume and appearance are
    /// reversible. Everything that touches another app, another person or the
    /// calendar is off until somebody turns it on, so the first run of the
    /// assistant cannot surprise anyone.
    public static let defaultEnabled: [ConnectorID] = [.files, .apps, .system]

    /// The shipped settings.
    public static let `default` = ConnectorSettings()

    /// Creates settings.
    ///
    /// - Parameters:
    ///   - enabled: the connectors that are on.
    ///   - policies: per-tool overrides.
    public init(enabled: [ConnectorID] = ConnectorSettings.defaultEnabled, policies: [String: ToolPolicy] = [:]) {
        self.enabled = enabled
        self.policies = policies
    }

    /// Whether a connector is switched on.
    public func isEnabled(_ id: ConnectorID) -> Bool {
        enabled.contains(id)
    }

    /// The policy table these settings describe.
    public var policyTable: ToolPolicyTable {
        ToolPolicyTable(overrides: policies)
    }

    /// Switches a connector on or off, keeping the order stable.
    public mutating func setEnabled(_ enabled: Bool, for id: ConnectorID) {
        if enabled {
            guard !self.enabled.contains(id) else { return }
            self.enabled.append(id)
        } else {
            self.enabled.removeAll { $0 == id }
            // A tool that is no longer offered must not keep an override that
            // would come back if the connector were re-enabled years later.
            policies = policies.filter { !$0.key.hasPrefix(id.rawValue + "_") }
        }
    }

    /// A tolerant decoder.
    ///
    /// Every key decodes through `try?` with a fallback, the same rule the rest
    /// of the configuration follows: a file edited by hand, or written by a
    /// newer build that knows a connector this one does not, still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stored = (try? container.decodeIfPresent([String].self, forKey: .enabled)) ?? nil {
            var seen: Set<ConnectorID> = []
            enabled = stored.map { ConnectorID($0) }.filter { seen.insert($0).inserted }
        } else {
            enabled = ConnectorSettings.defaultEnabled
        }
        if let stored = (try? container.decodeIfPresent([String: StoredPolicy].self, forKey: .policies)) ?? nil {
            var mapped: [String: ToolPolicy] = [:]
            for (key, value) in stored {
                guard let policy = value.policy else { continue }
                let modern = Self.modernToolName(key)
                // An explicit underscore key wins over a dotted alias, whatever
                // order the dictionary happens to iterate in.
                if mapped[modern] == nil || key == modern {
                    mapped[modern] = policy
                }
            }
            policies = mapped
        } else {
            policies = [:]
        }
    }

    /// Reads a tool name from a pre-release file.
    ///
    /// Tool names were dot-namespaced before the provider name rule was known.
    /// Only the separator changed, so replacing it recovers the key.
    ///
    /// - Parameter key: the stored key.
    /// - Returns: the current spelling.
    static func modernToolName(_ key: String) -> String {
        key.replacingOccurrences(of: ".", with: "_")
    }

    /// A policy value that decodes to nil instead of throwing.
    private struct StoredPolicy: Decodable {
        let policy: ToolPolicy?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                policy = nil
            } else {
                // The same tolerant rule as a keyed enum: a spelling this build
                // does not know drops that one override, never the file.
                policy = (try? container.decode(ToolPolicy.self)) ?? nil
            }
        }
    }
}
