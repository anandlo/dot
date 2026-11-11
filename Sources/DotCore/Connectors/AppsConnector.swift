import Foundation

/// Opening applications and URLs.
///
/// The cheapest useful connector and the one with the widest blast radius:
/// `open` hands a URL or a file to whatever handler claims it, and a `.command`
/// file is code execution. It is therefore annotated `external`, so every call
/// confirms, and a URL is limited to the schemes a person types on purpose.
public struct AppsConnector: Connector {
    public let id: ConnectorID = .apps
    public let displayName = "Apps and links"
    public let symbol = "app"
    public let detail = "Open an application, a web link, or a file."
    private let launcher: any AppLaunching
    private let files: any FileOperating
    private let safety: PathSafety

    /// Creates the connector.
    ///
    /// - Parameters:
    ///   - launcher: the workspace adapter.
    ///   - files: the file operations, used to open a file.
    ///   - safety: the path rules for `apps_openFile`.
    public init(launcher: any AppLaunching, files: any FileOperating, safety: PathSafety = PathSafety()) {
        self.launcher = launcher
        self.files = files
        self.safety = safety
    }

    public func tools() -> [ConnectorTool] {
        [openAppTool, openURLTool, openFileTool, runningTool]
    }

    private var openAppTool: ConnectorTool {
        ConnectorTool(
            name: "apps_open",
            title: "Open an app",
            description: "Open an application by its name, for example Slack or Music.",
            risk: .external,
            schema: ToolSchema([
                .init(name: "app", description: "The application's name.", field: .string(maxLength: 120)),
            ]),
            confirmation: { arguments in
                "Open \(arguments.string("app") ?? "that app")?"
            }
        )
    }

    private var openURLTool: ConnectorTool {
        ConnectorTool(
            name: "apps_openURL",
            title: "Open a link",
            description: "Open an http, https, mailto, tel or sms link in the default app.",
            risk: .external,
            schema: ToolSchema([
                .init(name: "url", description: "The link.", field: .string(maxLength: 2_000)),
            ]),
            confirmation: { arguments in
                "Open the link \(arguments.string("url") ?? "")?"
            }
        )
    }

    private var openFileTool: ConnectorTool {
        ConnectorTool(
            name: "apps_openFile",
            title: "Open a file",
            description: "Open a file from your home folder with its default application.",
            risk: .external,
            schema: ToolSchema([
                .init(name: "path", description: "The file path.", field: .string(maxLength: 1_024)),
            ]),
            confirmation: { arguments in
                "Open \"\(ResultText.shortPath(arguments.string("path") ?? ""))\"?"
            }
        )
    }

    private var runningTool: ConnectorTool {
        ConnectorTool(
            name: "apps_running",
            title: "List running apps",
            description: "List the applications that are open right now.",
            risk: .read,
            schema: ToolSchema([]),
            confirmation: { _ in "List your open apps." }
        )
    }

    public func permission() async -> ConnectorPermission {
        .notNeeded(service: "Applications")
    }

    public func requestAccess() async -> ConnectorPermission {
        .notNeeded(service: "Applications")
    }

    public func invoke(_ call: ConnectorCall) async -> ConnectorOutcome {
        do {
            switch call.name {
            case "apps_open":
                let name = call.arguments.string("app") ?? ""
                try await launcher.openApp(named: name)
                return .ok("Opened \(name).")
            case "apps_openURL":
                let url = try validURL(call.arguments.string("url") ?? "")
                try await launcher.open(url)
                return .ok("Opened \(url.absoluteString).")
            case "apps_openFile":
                let url = try safety.check(call.arguments.string("path") ?? "", intent: .read)
                guard await files.exists(url) else { throw StoreError("There is no file at that path.") }
                try await files.open(url)
                return .ok("Opened \(ResultText.shortPath(url.path)).")
            case "apps_running":
                let apps = await launcher.runningApplications()
                let lines = apps.map { app in
                    ResultText.line([app.name, app.isActive ? "frontmost" : nil])
                }
                return .ok(ResultText.list(heading: "app", items: lines, empty: "No app is open."))
            default:
                return .failure("Apps has no tool called '\(call.name)'.")
            }
        } catch let failure as PathSafety.Failure {
            return .failure(failure.message)
        } catch let error as StoreError {
            return .failure(error.message)
        } catch {
            return .failure("The app could not be opened.")
        }
    }

    /// A URL whose scheme a person would type, and nothing else.
    ///
    /// `file:` is refused here because opening a file has its own tool and its
    /// own path check; `javascript:`, `data:` and the rest are refused because
    /// no spoken sentence means them.
    private func validURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else {
            throw StoreError("That is not a link.")
        }
        let allowed: Set<String> = ["http", "https", "mailto", "tel", "sms"]
        guard allowed.contains(scheme) else {
            throw StoreError("Dot opens http, https, mailto, tel and sms links only.")
        }
        if scheme == "http" || scheme == "https" {
            guard let host = url.host, !host.isEmpty else { throw StoreError("That link has no address.") }
            guard url.user == nil else { throw StoreError("That link carries a user name, so Dot refuses it.") }
        }
        return url
    }
}
