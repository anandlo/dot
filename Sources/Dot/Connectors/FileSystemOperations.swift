import AppKit
import DotCore
import Foundation

/// The file operations, through `FileManager` and `NSWorkspace`.
///
/// Trash is `trashItem`, which is the only delete Dot has: there is no code
/// path that removes a file permanently. A move refuses to overwrite, so a
/// rename onto an existing name fails instead of destroying it.
final class FileSystemOperations: FileOperating, @unchecked Sendable {
    func open(_ url: URL) async throws {
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else {
            throw StoreError("No application on this Mac opens that file.")
        }
    }

    func reveal(_ url: URL) async throws {
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func move(_ source: URL, to destination: URL) async throws -> URL {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw StoreError("A file with that name is already there.")
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw StoreError("The file could not be moved. Check that both folders exist.")
        }
        return destination
    }

    func trash(_ url: URL) async throws -> URL {
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        } catch {
            throw StoreError("The file could not be moved to the Trash.")
        }
        return (resulting as URL?) ?? url
    }

    func exists(_ url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func size(of url: URL) async -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }
}

/// Opens applications, links and folders, through `NSWorkspace`.
final class WorkspaceLauncher: AppLaunching, @unchecked Sendable {
    func openApp(named name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120 else {
            throw StoreError("That is not an application name.")
        }
        guard !trimmed.contains("/"), !trimmed.contains("\0") else {
            throw StoreError("That is not an application name.")
        }
        guard let url = await Self.applicationURL(named: trimmed) else {
            throw StoreError("There is no application called \(trimmed).")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                    if error != nil {
                        continuation.resume(throwing: StoreError("That application could not be opened."))
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError("That application could not be opened.")
        }
    }

    func open(_ url: URL) async throws {
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else {
            throw StoreError("No application on this Mac opens that link.")
        }
    }

    func runningApplications() async -> [RunningApp] {
        await MainActor.run {
            var seen: Set<String> = []
            return NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app in
                    let identifier = app.bundleIdentifier ?? app.localizedName ?? ""
                    guard !identifier.isEmpty, seen.insert(identifier).inserted else { return nil }
                    return RunningApp(
                        name: app.localizedName ?? identifier,
                        bundleID: app.bundleIdentifier,
                        isActive: app.isActive
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.isActive != rhs.isActive { return lhs.isActive }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
        }
    }

    /// Resolves an application name to a bundle, without launching anything.
    ///
    /// A bundle identifier is tried first, then the three folders applications
    /// live in. Nothing outside them is searched: a path from the model is not
    /// an application name, and `open` on an arbitrary path is code execution.
    private static func applicationURL(named name: String) async -> URL? {
        await MainActor.run {
            if name.contains("."),
               let byIdentifier = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
                return byIdentifier
            }
            let home = NSHomeDirectory()
            let candidates = [
                "/Applications/\(name).app",
                "/System/Applications/\(name).app",
                "/System/Applications/Utilities/\(name).app",
                "\(home)/Applications/\(name).app",
            ]
            return candidates
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
    }
}
