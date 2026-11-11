import Foundation

/// Writes the files Dot keeps for itself with permissions only its owner can use.
///
/// Every file written here holds something that is nobody else's business:
/// what a person dictated, where their speech is sent, what the app did. A file
/// created with the usual umask is `0644`, which every other account on the
/// same Mac can read. These helpers create the folder `0700` and the file
/// `0600` from the moment either exists, and they replace the file atomically
/// so a crash cannot leave a half-written configuration behind.
public enum SecureFile {
    /// The permissions of a folder that holds Dot's own files.
    public static let directoryPermissions = 0o700
    /// The permissions of a file Dot writes.
    public static let filePermissions = 0o600

    /// Creates a folder, with every folder above it, and restricts it to its
    /// owner.
    ///
    /// Only the last component is changed: the folders above it belong to the
    /// person's home directory and are not Dot's to touch.
    ///
    /// - Parameter url: the folder to create.
    /// - Throws: the error `FileManager` reported when the folder cannot be
    ///   created.
    public static func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tighten(url, mode: directoryPermissions)
    }

    /// Writes `data` to `url`, replacing any file that is there.
    ///
    /// The bytes go into a temporary file in the same folder that is created
    /// `0600`, and the temporary file is renamed over the destination. The
    /// destination therefore has the restricted permissions from its first
    /// byte, and a reader never sees a partial write.
    ///
    /// - Parameters:
    ///   - data: the bytes to write.
    ///   - url: the file to write.
    /// - Throws: ``SecureFileError`` when the file cannot be created or
    ///   replaced.
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try createDirectory(at: directory)
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(filePermissions))
        guard descriptor >= 0 else {
            throw SecureFileError.cannotCreate(temporary.path)
        }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            // No `synchronize` here: the rename below is what makes the write
            // atomic, and the caller of this on the launch path is the main
            // actor. An fsync per preference change is milliseconds spent
            // waiting for a disk to protect a file that is rewritten anyway.
            try handle.close()
        } catch {
            unlink(temporary.path)
            throw SecureFileError.cannotWrite(temporary.path)
        }
        guard rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw SecureFileError.cannotReplace(url.path)
        }
    }

    /// Restricts an existing file or folder to its owner.
    ///
    /// A file written by an older build is still `0644` on disk until it is
    /// written again, so the reader-side of the app repairs what it can.
    ///
    /// - Parameters:
    ///   - url: the file or folder to restrict.
    ///   - mode: the permissions to set, `0600` for a file and `0700` for a
    ///     folder by default.
    @discardableResult
    public static func tighten(_ url: URL, mode: Int = filePermissions) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        guard permissions(of: url) != mode else { return true }
        return (try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: url.path
        )) != nil
    }

    /// The permissions of a file or folder, as an octal mode.
    ///
    /// - Parameter url: the file or folder to read.
    /// - Returns: the mode, or `nil` when it cannot be read.
    public static func permissions(of url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }
}

/// A file Dot keeps for itself could not be written.
public enum SecureFileError: Error, Equatable, LocalizedError {
    /// The temporary file could not be created.
    case cannotCreate(String)
    /// The bytes could not be written into the temporary file.
    case cannotWrite(String)
    /// The temporary file could not be renamed over the destination.
    case cannotReplace(String)

    public var errorDescription: String? {
        switch self {
        case .cannotCreate(let path): "Dot could not create \(path)."
        case .cannotWrite(let path): "Dot could not write \(path)."
        case .cannotReplace(let path): "Dot could not replace \(path)."
        }
    }
}
