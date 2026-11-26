import AppKit
import Darwin
import DotCore
import Foundation

struct MonotonicDeadline: Sendable {
    static var nowNanoseconds: UInt64 {
        var time = timespec()
        guard clock_gettime(CLOCK_MONOTONIC, &time) == 0 else { return 0 }
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }

    private let deadlineNanoseconds: UInt64

    static func after(milliseconds: UInt64) -> MonotonicDeadline {
        MonotonicDeadline(deadlineNanoseconds: nowNanoseconds + milliseconds * 1_000_000)
    }

    var isExpired: Bool { isExpired(at: Self.nowNanoseconds) }

    var remainingMilliseconds: Int32 {
        let now = Self.nowNanoseconds
        guard deadlineNanoseconds > now else { return 0 }
        let remaining = (deadlineNanoseconds - now + 999_999) / 1_000_000
        return Int32(min(remaining, UInt64(Int32.max)))
    }

    func isExpired(at now: UInt64) -> Bool { now >= deadlineNanoseconds }
}

enum SingleInstanceFailure: Error, CustomStringConvertible {
    case insecureDirectory(String)
    case insecureLock(String)
    case insecureSocket(String)
    case socket(String)
    case handshake(String)
    case handoffTimedOut

    var description: String {
        switch self {
        case .insecureDirectory(let detail): "Dot: insecure single-instance directory: \(detail)"
        case .insecureLock(let detail): "Dot: insecure single-instance lock: \(detail)"
        case .insecureSocket(let detail): "Dot: insecure reopen socket: \(detail)"
        case .socket(let detail): "Dot: reopen socket error: \(detail)"
        case .handshake(let detail): "Dot: reopen hand-off failed: \(detail)"
        case .handoffTimedOut: "Dot: reopen hand-off timed out"
        }
    }
}

enum SingleInstanceAcquisition: Equatable, Sendable {
    case primary
    case secondary
}

enum SingleInstanceAttempt: Equatable, Sendable {
    case acquired
    case contended
}

struct SingleInstancePaths: Sendable {
    let directoryPath: String
    let lockPath: String
    let socketPath: String

#if DEBUG
    private static let testBaseLock = NSLock()
    nonisolated(unsafe) private static var testBaseDirectory: String?

    static func setTestBaseDirectory(_ path: String?) {
        testBaseLock.lock()
        testBaseDirectory = path
        testBaseLock.unlock()
    }
#endif

    static var defaultBaseDirectory: String {
#if DEBUG
        testBaseLock.lock()
        defer { testBaseLock.unlock() }
        if let testBaseDirectory { return testBaseDirectory }
#endif
        return DotConfig.directoryURL().path
    }

    init(baseDirectory: String? = nil) throws {
        let base = baseDirectory ?? Self.defaultBaseDirectory
        let directory = (base as NSString).appendingPathComponent("dot-\(geteuid())")
        try Self.ensurePrivateDirectory(directory)

        let lock = (directory as NSString).appendingPathComponent("instance.lock")
        try Self.ensureLockInode(lock)

        let socket = (directory as NSString).appendingPathComponent("reopen.sock")
        guard UnixSocketPath.fits(socket) else {
            throw SingleInstanceFailure.socket("reopen socket path exceeds sun_path")
        }

        self.directoryPath = directory
        self.lockPath = lock
        self.socketPath = socket
    }

    private static func ensurePrivateDirectory(_ path: String) throws {
        var information = stat()
        if lstat(path, &information) != 0 {
            guard errno == ENOENT else {
                throw SingleInstanceFailure.insecureDirectory("lstat failed (\(errno))")
            }
            do {
                try SecureFile.createDirectory(at: URL(fileURLWithPath: path))
            } catch {
                throw SingleInstanceFailure.insecureDirectory("createDirectory failed (\(error))")
            }
        }
        guard lstat(path, &information) == 0 else {
            throw SingleInstanceFailure.insecureDirectory("lstat failed (\(errno))")
        }
        guard information.st_mode & S_IFMT != S_IFLNK,
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == geteuid(),
              information.st_mode & 0o777 == 0o700 else {
            throw SingleInstanceFailure.insecureDirectory("expected an owned 0700 directory")
        }
    }

    private static func ensureLockInode(_ path: String) throws {
        let descriptor = open(
            path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw SingleInstanceFailure.insecureLock("open failed (\(errno))")
        }
        defer { close(descriptor) }
        try verifyLockDescriptor(descriptor)
    }

    fileprivate static func verifyLockDescriptor(_ descriptor: Int32) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw SingleInstanceFailure.insecureLock("fstat failed (\(errno))")
        }
        guard information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_mode & 0o777 == 0o600 else {
            throw SingleInstanceFailure.insecureLock("expected an owned 0600 regular file")
        }
    }
}

final class SingleInstanceLease: @unchecked Sendable {
    let path: String
    private let stateLock = NSLock()
    private var descriptor: Int32?

    var isHeld: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return descriptor != nil
    }

    init(path: String) {
        self.path = path
    }

    deinit {
        if let descriptor { close(descriptor) }
    }

    func acquire() throws -> SingleInstanceAttempt {
        stateLock.lock()
        defer { stateLock.unlock() }
        if descriptor != nil { return .acquired }

        let opened = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        guard opened >= 0 else {
            throw SingleInstanceFailure.insecureLock("open failed (\(errno))")
        }
        do {
            try SingleInstancePaths.verifyLockDescriptor(opened)
            if flock(opened, LOCK_EX | LOCK_NB) == 0 {
                descriptor = opened
                return .acquired
            }
            let error = errno
            if error == EWOULDBLOCK || error == EAGAIN {
                close(opened)
                return .contended
            }
            throw SingleInstanceFailure.insecureLock("flock failed (\(error))")
        } catch {
            close(opened)
            throw error
        }
    }

    func release() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let descriptor else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        self.descriptor = nil
    }
}

/// The blocking acquisition phase. It owns no AppKit state, so a test can run
/// an ordinary contender on a worker while the owner closes in an orderly way.
final class SingleInstanceClaimant: @unchecked Sendable {
    let paths: SingleInstancePaths
    let lease: SingleInstanceLease

    private let stateLock = NSLock()
    private var transientHandler: (@Sendable () -> Void)?
    private var transientCountValue = 0

    init(baseDirectory: String? = nil) throws {
        self.paths = try SingleInstancePaths(baseDirectory: baseDirectory)
        self.lease = SingleInstanceLease(path: paths.lockPath)
    }

    var transientCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return transientCountValue
    }

    func setTransientHandler(_ handler: @escaping @Sendable () -> Void) {
        stateLock.lock()
        transientHandler = handler
        stateLock.unlock()
    }

    func acquireOrHandOff(
        deadline: MonotonicDeadline,
        attemptMilliseconds: UInt64 = 250
    ) throws -> SingleInstanceAcquisition {
        while true {
            guard !deadline.isExpired else { throw SingleInstanceFailure.handoffTimedOut }
            switch try lease.acquire() {
            case .acquired:
                return .primary
            case .contended:
                let remaining = UInt64(max(1, deadline.remainingMilliseconds))
                let attemptDeadline = MonotonicDeadline.after(
                    milliseconds: min(attemptMilliseconds, remaining)
                )
                switch try ReopenClient.request(
                    socketPath: paths.socketPath,
                    deadline: attemptDeadline,
                    responseDeadline: deadline,
                    allowTransientLooseMode: true
                ) {
                case .acknowledged:
                    return .secondary
                case .transient, .timedOut:
                    noteTransient()
                    guard !deadline.isExpired else { throw SingleInstanceFailure.handoffTimedOut }
                    let interval = min(deadline.remainingMilliseconds, 10)
                    if interval > 0 {
                        let result = poll(nil, 0, interval)
                        guard result >= 0 || errno == EINTR else {
                            throw SingleInstanceFailure.handshake("poll failed (\(errno))")
                        }
                    }
                }
            }
        }
    }

    private func noteTransient() {
        stateLock.lock()
        transientCountValue += 1
        let handler = transientHandler
        stateLock.unlock()
        handler?()
    }
}

@MainActor
final class SingleInstanceCoordinator {
    /// Longer than `Shutdown.archiveLimit` (2 s) so a contender can wait through
    /// an orderly quit and then take the released lease.
    nonisolated static let handoffDeadlineMilliseconds: UInt64 = 10_000
    nonisolated static let handoffAttemptMilliseconds: UInt64 = 250

    static var shared: SingleInstanceCoordinator?

    let claimant: SingleInstanceClaimant
    private(set) var server: ReopenServer?

    var paths: SingleInstancePaths { claimant.paths }

    init(baseDirectory: String? = nil) throws {
        self.claimant = try SingleInstanceClaimant(baseDirectory: baseDirectory)
    }

    func tryAcquire() throws -> SingleInstanceAttempt {
        try claimant.lease.acquire()
    }

    func acquireOrHandOff(deadline: MonotonicDeadline) throws -> SingleInstanceAcquisition {
        let acquisition = try claimant.acquireOrHandOff(
            deadline: deadline,
            attemptMilliseconds: Self.handoffAttemptMilliseconds
        )
        guard acquisition == .primary else { return acquisition }
        do {
            server = try ReopenServer(socketPath: paths.socketPath)
            return acquisition
        } catch {
            claimant.lease.release()
            throw error
        }
    }

    func startReopenLoop() {
        server?.startTimer()
    }

    func markReady(_ handler: @escaping @MainActor () -> Void) {
        server?.markReady(handler)
    }

    func pumpReopen() {
        server?.pump()
    }

    func beginShutdown() {
        server?.beginShutdown()
    }

    func close() {
        beginShutdown()
        claimant.lease.release()
        if Self.shared === self { Self.shared = nil }
    }
}

enum SingleInstance {
    /// Whether this process is a test host or a one-shot tool that must not
    /// create or join a user-facing app lease.
    @MainActor
    static func bypassesCoordinator(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments,
        hasXCTestClass: Bool = NSClassFromString("XCTest") != nil
    ) -> Bool {
        if runsUnderXCTest(environment: environment, hasXCTestClass: hasXCTestClass) { return true }
        if isExplicitTestTriggerLaunch(environment: environment, arguments: arguments) { return true }
        if arguments.contains(MenuDump.argument) { return true }
        return HUDPreview.requestedDirectory(environment: environment, arguments: arguments) != nil
            || DemoRender.requestedDirectory(environment: environment, arguments: arguments) != nil
            || UIPreview.requestedMotionDirectory(arguments: arguments) != nil
            || UIPreview.requestedDirectory(environment: environment, arguments: arguments) != nil
            || IconRender.requestedDirectory(environment: environment, arguments: arguments) != nil
    }

    /// XCTest loads the app as a library and never runs `DotMain.main`, but a
    /// test host that does start it must still be left alone.
    static func runsUnderXCTest(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        hasXCTestClass: Bool = NSClassFromString("XCTest") != nil
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || hasXCTestClass
    }

    /// An explicit, trigger-enabled launch is a developer tool, not a second
    /// user-facing Dot: it has to be able to drive the app without being handed
    /// off to an instance that has no trigger.
    static func isExplicitTestTriggerLaunch(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        guard DotMigration.environment("TEST_TRIGGER", in: environment) != nil else { return false }
        return arguments.contains("--allow-test-trigger")
    }
}
