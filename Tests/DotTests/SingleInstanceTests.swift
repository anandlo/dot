import Foundation
import XCTest
@testable import Dot
import DotCore

private enum TestError: Error {
    case statFailed(String)
    case forcedListenFailure
    case temporaryDirectory
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: ReopenRequestResult?

    var value: ReopenRequestResult? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private final class AcquisitionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: SingleInstanceAcquisition?

    var value: SingleInstanceAcquisition? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private final class ClaimResultsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Result<SingleInstanceAcquisition, Error>] = []

    func append(_ result: Result<SingleInstanceAcquisition, Error>) {
        lock.lock()
        storage.append(result)
        lock.unlock()
    }

    var values: [Result<SingleInstanceAcquisition, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class IndexedClaimResultsBox: @unchecked Sendable {
    struct Entry {
        let index: Int
        let result: Result<SingleInstanceAcquisition, Error>
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    func append(index: Int, result: Result<SingleInstanceAcquisition, Error>) {
        lock.lock()
        storage.append(Entry(index: index, result: result))
        lock.unlock()
    }

    var values: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class RawServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var error: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private func makeInjectedSupportDirectory() throws -> (base: String, support: String) {
    let template = "/tmp/dot4-XXXXXX"
    var bytes = Array(template.utf8CString)
    guard mkdtemp(bytes.withUnsafeMutableBufferPointer { $0.baseAddress }) != nil else {
        throw TestError.temporaryDirectory
    }
    let base = String(cString: bytes.withUnsafeMutableBufferPointer { $0.baseAddress! })
    let support = (base as NSString).appendingPathComponent("Library/Application Support/Dot")
    try FileManager.default.createDirectory(
        atPath: support,
        withIntermediateDirectories: true
    )
    return (base, support)
}

private func makeTemporaryDirectory() throws -> String {
    let template = (NSTemporaryDirectory() as NSString).appendingPathComponent("dot-single-instance-XXXXXX")
    var bytes = Array(template.utf8CString)
    return bytes.withUnsafeMutableBufferPointer { buffer in
        guard mkdtemp(buffer.baseAddress) != nil else { return "" }
        return String(cString: buffer.baseAddress!)
    }
}

private func fileIdentity(_ path: String) throws -> (dev: UInt64, inode: UInt64) {
    var info = stat()
    guard lstat(path, &info) == 0 else { throw TestError.statFailed(path) }
    return (UInt64(info.st_dev), UInt64(info.st_ino))
}

private func makeBoundSocket(at path: String) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw TestError.statFailed(path) }
    let bytes = Array(path.utf8) + [0]
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    _ = bytes.withUnsafeBytes { source in
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            memcpy(destination.baseAddress, source.baseAddress, bytes.count)
        }
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
            Darwin.bind(descriptor, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0 else {
        close(descriptor)
        throw TestError.statFailed(path)
    }
    return descriptor
}

private func makeStaleSocket(at path: String, mode: mode_t) throws -> (dev: UInt64, inode: UInt64) {
    let descriptor = try makeBoundSocket(at: path)
    defer { close(descriptor) }
    guard chmod(path, mode) == 0 else { throw TestError.statFailed(path) }
    return try fileIdentity(path)
}

private func connectToUnixSocket(at path: String) -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return -1 }
    defer { close(descriptor) }
    let bytes = Array(path.utf8) + [0]
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    _ = bytes.withUnsafeBytes { source in
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            memcpy(destination.baseAddress, source.baseAddress, bytes.count)
        }
    }
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
            Darwin.connect(descriptor, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func connectRawClient(at path: String) -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return -1 }
    var noSIGPIPE: Int32 = 1
    _ = withUnsafePointer(to: &noSIGPIPE) { pointer in
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            pointer,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }
    let bytes = Array(path.utf8) + [0]
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    _ = bytes.withUnsafeBytes { source in
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            memcpy(destination.baseAddress, source.baseAddress, bytes.count)
        }
    }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
            Darwin.connect(descriptor, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if connected != 0 {
        close(descriptor)
        return -1
    }
    return descriptor
}

@MainActor
private func pumpMainRunLoop(for duration: TimeInterval) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        RunLoop.current.run(
            mode: .default,
            before: min(deadline, Date().addingTimeInterval(0.02))
        )
    }
}

@MainActor
private func waitForSignal(_ semaphore: DispatchSemaphore, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if semaphore.wait(timeout: .now()) == .success { return true }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return semaphore.wait(timeout: .now()) == .success
}

@MainActor
private func waitForPendingCount(_ server: ReopenServer?, minimum: Int, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if (server?.pendingCount ?? 0) >= minimum { return true }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return (server?.pendingCount ?? 0) >= minimum
}

private func startPeerServer(
    at path: String,
    connections: Int,
    acknowledgeLast: Bool,
    listening: DispatchSemaphore,
    finished: DispatchSemaphore,
    state: RawServerState
) {
    DispatchQueue.global(qos: .userInitiated).async {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            state.error = "socket failed"
            listening.signal()
            finished.signal()
            return
        }
        let bytes = Array(path.utf8) + [0]
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        _ = bytes.withUnsafeBytes { source in
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                memcpy(destination.baseAddress, source.baseAddress, bytes.count)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(descriptor, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
            state.error = "bind, chmod or listen failed"
            close(descriptor)
            listening.signal()
            finished.signal()
            return
        }
        listening.signal()

        for index in 0..<connections {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else {
                state.error = "accept failed"
                break
            }
            var request: UInt8 = 0
            _ = withUnsafeMutablePointer(to: &request) { pointer in
                recv(client, pointer, 1, 0)
            }
            if acknowledgeLast && index == connections - 1 {
                var acknowledgement: UInt8 = 0x41
                _ = withUnsafePointer(to: &acknowledgement) { pointer in
                    send(client, pointer, 1, 0)
                }
            }
            close(client)
        }
        close(descriptor)
        _ = unlink(path)
        finished.signal()
    }
}

@MainActor
private func primaryCoordinator(in directory: String) throws -> SingleInstanceCoordinator {
    let coordinator = try SingleInstanceCoordinator(baseDirectory: directory)
    let acquisition = try coordinator.acquireOrHandOff(deadline: .after(milliseconds: 1_000))
    XCTAssertEqual(acquisition, .primary)
    return coordinator
}

@MainActor
final class SingleInstanceCoordinatorTests: XCTestCase {
    private let temporaryDirectory = try! makeTemporaryDirectory()

    func testIndependentLockDescriptorContention() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let paths = try SingleInstancePaths(baseDirectory: temporaryDirectory)
        let descriptor = open(
            paths.lockPath,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { close(descriptor) } }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        let coordinator = try SingleInstanceCoordinator(baseDirectory: temporaryDirectory)
        XCTAssertEqual(try coordinator.tryAcquire(), .contended)

        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        XCTAssertEqual(try coordinator.tryAcquire(), .acquired)
        coordinator.beginShutdown()
        coordinator.close()
    }

    func testOwnerLossReleasesLeaseWithoutReplacingInode() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let coordinator = try primaryCoordinator(in: temporaryDirectory)
        let paths = coordinator.paths
        let before = try fileIdentity(paths.lockPath)

        coordinator.beginShutdown()
        coordinator.close()

        let after = try fileIdentity(paths.lockPath)
        XCTAssertEqual(before.dev, after.dev)
        XCTAssertEqual(before.inode, after.inode)

        let descriptor = open(
            paths.lockPath,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { close(descriptor) } }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
    }

    func testHandoffIsAcknowledgedOnlyAfterReadyHandlerRuns() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let coordinator = try primaryCoordinator(in: temporaryDirectory)
        let socketPath = coordinator.paths.socketPath
        let requestSent = DispatchSemaphore(value: 0)
        let requestFinished = DispatchSemaphore(value: 0)
        let result = ResultBox()

        DispatchQueue.global(qos: .userInitiated).async {
            result.value = try? ReopenClient.request(
                socketPath: socketPath,
                deadline: .after(milliseconds: 2_000)
            ) {
                requestSent.signal()
            }
            requestFinished.signal()
        }

        XCTAssertEqual(requestSent.wait(timeout: .now() + 2), .success)
        coordinator.pumpReopen()
        XCTAssertEqual(coordinator.server?.pendingCount, 1)
        XCTAssertEqual(coordinator.server?.acknowledgedCount, 0)

        var readyCalls = 0
        coordinator.markReady { readyCalls += 1 }
        XCTAssertEqual(coordinator.server?.acknowledgedCount, 1)
        XCTAssertEqual(readyCalls, 1)
        XCTAssertEqual(requestFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(result.value, .acknowledged)

        coordinator.beginShutdown()
        coordinator.close()
    }

    func testContenderTakesOverAfterOrderlyOwnerClosure() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let owner = try primaryCoordinator(in: temporaryDirectory)
        owner.beginShutdown()

        let claimant = try SingleInstanceClaimant(baseDirectory: temporaryDirectory)
        let sawTransient = DispatchSemaphore(value: 0)
        claimant.setTransientHandler { sawTransient.signal() }
        let result = AcquisitionBox()
        let finished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            result.value = try? claimant.acquireOrHandOff(
                deadline: .after(milliseconds: SingleInstanceCoordinator.handoffDeadlineMilliseconds)
            )
            finished.signal()
        }

        XCTAssertEqual(sawTransient.wait(timeout: .now() + 2), .success)
        XCTAssertNil(result.value)
        owner.close()
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(result.value, .primary)
    }

    func testSimultaneousOrdinaryLaunchHasOneOwnerAndOneHandoff() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let paths = try SingleInstancePaths(baseDirectory: temporaryDirectory)
        let listening = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let state = RawServerState()
        startPeerServer(
            at: paths.socketPath,
            connections: 1,
            acknowledgeLast: true,
            listening: listening,
            finished: finished,
            state: state
        )
        XCTAssertEqual(listening.wait(timeout: .now() + 2), .success)

        let first = try SingleInstanceClaimant(baseDirectory: temporaryDirectory)
        let second = try SingleInstanceClaimant(baseDirectory: temporaryDirectory)
        let results = ClaimResultsBox()
        let start = DispatchSemaphore(value: 0)
        let claimantsFinished = DispatchSemaphore(value: 0)

        for claimant in [first, second] {
            DispatchQueue.global(qos: .userInitiated).async {
                start.wait()
                do {
                    results.append(.success(try claimant.acquireOrHandOff(
                        deadline: .after(milliseconds: SingleInstanceCoordinator.handoffDeadlineMilliseconds)
                    )))
                } catch {
                    results.append(.failure(error))
                }
                claimantsFinished.signal()
            }
        }
        start.signal()
        start.signal()
        XCTAssertEqual(claimantsFinished.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(claimantsFinished.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)

        let acquisitions = results.values.compactMap { try? $0.get() }
        XCTAssertEqual(results.values.count, 2)
        XCTAssertEqual(acquisitions.filter { $0 == .primary }.count, 1)
        XCTAssertEqual(acquisitions.filter { $0 == .secondary }.count, 1)
        XCTAssertNil(state.error)
        first.lease.release()
        second.lease.release()
    }

    func testStaleOwnedSocketWithLooseModeIsRecovered() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let paths = try SingleInstancePaths(baseDirectory: temporaryDirectory)
        let stale = try makeStaleSocket(at: paths.socketPath, mode: 0o755)

        let server = try ReopenServer(socketPath: paths.socketPath)
        defer { server.beginShutdown() }
        let recovered = try fileIdentity(paths.socketPath)
        XCTAssertNotEqual(stale.inode, recovered.inode)

        var information = stat()
        XCTAssertEqual(lstat(paths.socketPath, &information), 0)
        XCTAssertEqual(information.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(information.st_uid, geteuid())
        XCTAssertEqual(information.st_mode & 0o777, 0o600)
    }

    func testNonSocketAtSocketPathIsNotRemoved() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let paths = try SingleInstancePaths(baseDirectory: temporaryDirectory)
        try Data("not a socket".utf8).write(to: URL(fileURLWithPath: paths.socketPath))

        XCTAssertThrowsError(try ReopenServer(socketPath: paths.socketPath)) { error in
            XCTAssertTrue(String(describing: error).localizedCaseInsensitiveContains("socket"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.socketPath))
    }

    func testFailedSetupRemovesSocketCreatedByThatAttempt() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let paths = try SingleInstancePaths(baseDirectory: temporaryDirectory)

        XCTAssertThrowsError(try ReopenServer(socketPath: paths.socketPath) {
            throw TestError.forcedListenFailure
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.socketPath))
    }

    func testClientRejectsSocketWithUnsafePathMode() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let paths = try SingleInstancePaths(baseDirectory: temporaryDirectory)
        _ = try makeStaleSocket(at: paths.socketPath, mode: 0o644)

        XCTAssertThrowsError(try ReopenClient.request(
            socketPath: paths.socketPath,
            deadline: .after(milliseconds: 50)
        )) { error in
            XCTAssertTrue(String(describing: error).localizedCaseInsensitiveContains("socket"))
        }
    }

    func testReadyHandlerThatShutsDownSendsNoACKAndClosesPendingOnce() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let coordinator = try primaryCoordinator(in: temporaryDirectory)
        let socketPath = coordinator.paths.socketPath
        let requestSent = DispatchSemaphore(value: 0)
        let requestFinished = DispatchSemaphore(value: 0)
        let result = ResultBox()
        guard let counters = coordinator.server?.debugCounters else {
            XCTFail("Primary server is missing")
            return
        }
        counters.reset()

        DispatchQueue.global(qos: .userInitiated).async {
            result.value = try? ReopenClient.request(
                socketPath: socketPath,
                deadline: .after(milliseconds: 2_000)
            ) {
                requestSent.signal()
            }
            requestFinished.signal()
        }

        XCTAssertTrue(waitForSignal(requestSent, timeout: 2))
        coordinator.pumpReopen()
        XCTAssertEqual(coordinator.server?.pendingCount, 1)

        coordinator.markReady { coordinator.beginShutdown() }
        XCTAssertEqual(coordinator.server?.readyHandlerCallCount, 1)
        XCTAssertEqual(coordinator.server?.acknowledgedCount, 0)
        XCTAssertEqual(coordinator.server?.pendingCount, 0)
        XCTAssertTrue(coordinator.server?.isShuttingDown == true)
        XCTAssertTrue(waitForSignal(requestFinished, timeout: 2))
        XCTAssertEqual(result.value, .transient)

        let accepted = counters.acceptedDescriptors
        XCTAssertEqual(accepted.count, 1)
        let cancelDeadline = Date().addingTimeInterval(1)
        while accepted.contains(where: { counters.closeCount(for: $0) != 1 }),
              Date() < cancelDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThanOrEqual(counters.peerCancels, 1)
        for descriptor in accepted {
            XCTAssertEqual(counters.closeCount(for: descriptor), 1)
        }

        coordinator.close()
    }

    func testShutdownStopsServerButHoldsLeaseUntilClose() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let coordinator = try primaryCoordinator(in: temporaryDirectory)
        let paths = coordinator.paths

        coordinator.beginShutdown()

        let descriptor = open(
            paths.lockPath,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { close(descriptor) } }
        XCTAssertNotEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.socketPath))
        XCTAssertNotEqual(
            try ReopenClient.request(
                socketPath: paths.socketPath,
                deadline: .after(milliseconds: 50)
            ),
            .acknowledged
        )

        coordinator.close()
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
    }

    func testHandoffTimesOutWhenServerIsUnavailable() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let owner = try primaryCoordinator(in: temporaryDirectory)
        owner.beginShutdown()
        defer { owner.close() }

        let contender = try SingleInstanceCoordinator(baseDirectory: temporaryDirectory)
        XCTAssertThrowsError(
            try contender.acquireOrHandOff(deadline: .after(milliseconds: 50))
        ) { error in
            XCTAssertTrue(String(describing: error).contains("timed out"))
        }
    }

    func testClosedPeerReturnsTransientWithoutClientSideRetry() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let socketPath = try SingleInstancePaths(baseDirectory: temporaryDirectory).socketPath
        let listening = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let state = RawServerState()
        startPeerServer(
            at: socketPath,
            connections: 1,
            acknowledgeLast: false,
            listening: listening,
            finished: finished,
            state: state
        )
        XCTAssertEqual(listening.wait(timeout: .now() + 2), .success)

        let result = try ReopenClient.request(
            socketPath: socketPath,
            deadline: .after(milliseconds: 2_000)
        )
        XCTAssertEqual(result, .transient)
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertNil(state.error)
    }

    func testHandoffDeadlineExceedsShutdownArchiveLimit() {
        XCTAssertEqual(Shutdown.archiveLimit, .seconds(2))
        XCTAssertGreaterThan(
            SingleInstanceCoordinator.handoffDeadlineMilliseconds,
            2_000
        )
    }

    func testSymlinkedLockIsRejected() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let paths = try SingleInstancePaths(baseDirectory: temporaryDirectory)
        let target = paths.lockPath + ".target"
        try Data("lock target".utf8).write(to: URL(fileURLWithPath: target))
        try FileManager.default.removeItem(atPath: paths.lockPath)
        try FileManager.default.createSymbolicLink(atPath: paths.lockPath, withDestinationPath: target)

        XCTAssertThrowsError(try SingleInstancePaths(baseDirectory: temporaryDirectory)) { error in
            XCTAssertTrue(String(describing: error).localizedCaseInsensitiveContains("lock"))
        }
    }

    func testLooseOwnedSocketIsRetryableWhilePrimaryLockIsHeld() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let paths = try SingleInstancePaths(baseDirectory: temporaryDirectory)
        let lockDescriptor = open(
            paths.lockPath,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        XCTAssertGreaterThanOrEqual(lockDescriptor, 0)
        defer { if lockDescriptor >= 0 { close(lockDescriptor) } }
        XCTAssertEqual(flock(lockDescriptor, LOCK_EX | LOCK_NB), 0)
        defer { _ = flock(lockDescriptor, LOCK_UN) }

        _ = try makeStaleSocket(at: paths.socketPath, mode: 0o755)
        let claimant = try SingleInstanceClaimant(baseDirectory: temporaryDirectory)
        let results = ClaimResultsBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                results.append(.success(try claimant.acquireOrHandOff(
                    deadline: .after(milliseconds: 2_000)
                )))
            } catch {
                results.append(.failure(error))
            }
            finished.signal()
        }

        Thread.sleep(forTimeInterval: 0.25)
        let server = try ReopenServer(socketPath: paths.socketPath)
        server.startTimer()
        defer { server.beginShutdown() }
        server.markReady { }

        XCTAssertTrue(waitForSignal(finished, timeout: 3))
        XCTAssertEqual(results.values.count, 1)
        for case .failure(let error) in results.values {
            XCTAssertFalse(
                String(describing: error).localizedCaseInsensitiveContains("insecure"),
                "A temporarily loose owned socket must be retryable while the primary holds the lease"
            )
        }
        XCTAssertEqual(results.values.compactMap { try? $0.get() }, [.secondary])
        XCTAssertEqual(server.readyHandlerCallCount, 1)
    }

    func testSlowPrimaryHandOffSendsOneReopenAndOneAck() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let owner = try primaryCoordinator(in: temporaryDirectory)
        owner.startReopenLoop()
        defer { owner.beginShutdown(); owner.close() }

        let contender = try SingleInstanceClaimant(baseDirectory: temporaryDirectory)
        let results = ClaimResultsBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                results.append(.success(try contender.acquireOrHandOff(
                    deadline: .after(milliseconds: SingleInstanceCoordinator.handoffDeadlineMilliseconds)
                )))
            } catch {
                results.append(.failure(error))
            }
            finished.signal()
        }

        XCTAssertTrue(waitForPendingCount(owner.server, minimum: 1, timeout: 2))
        pumpMainRunLoop(for: 0.85)

        var reopenCalls = 0
        owner.markReady { reopenCalls += 1 }
        XCTAssertTrue(waitForSignal(finished, timeout: 3))
        XCTAssertEqual(reopenCalls, 1)
        XCTAssertEqual(owner.server?.readyHandlerCallCount, 1)
        XCTAssertEqual(owner.server?.acknowledgedCount, 1)
        XCTAssertEqual(results.values.count, 1)
        XCTAssertEqual(results.values.compactMap { try? $0.get() }, [.secondary])
        XCTAssertEqual(contender.transientCount, 0)
    }

    func testDelayedRequestByteOnAcceptedPeerWakesServer() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let coordinator = try primaryCoordinator(in: temporaryDirectory)
        coordinator.startReopenLoop()
        defer { coordinator.beginShutdown(); coordinator.close() }

        var reopenCalls = 0
        coordinator.markReady { reopenCalls += 1 }
        let socketPath = coordinator.paths.socketPath
        let acknowledged = DispatchSemaphore(value: 0)
        let state = RawServerState()

        DispatchQueue.global(qos: .userInitiated).async {
            let descriptor = connectRawClient(at: socketPath)
            guard descriptor >= 0 else {
                state.error = "connect failed"
                acknowledged.signal()
                return
            }
            defer { close(descriptor) }
            Thread.sleep(forTimeInterval: 0.15)
            var request = ReopenClient.requestByte
            let sent = withUnsafePointer(to: &request) { send(descriptor, $0, 1, 0) }
            guard sent == 1 else {
                state.error = "send failed"
                acknowledged.signal()
                return
            }
            var reply: UInt8 = 0
            let received = withUnsafeMutablePointer(to: &reply) {
                recv(descriptor, $0, 1, 0)
            }
            if received == 1 && reply == ReopenClient.acknowledgementByte {
                acknowledged.signal()
            } else {
                state.error = "ack failed"
                acknowledged.signal()
            }
        }

        XCTAssertTrue(
            waitForSignal(acknowledged, timeout: 1),
            "A delayed request byte must wake the server without another connection"
        )
        XCTAssertNil(state.error)
        XCTAssertEqual(reopenCalls, 1)
        XCTAssertEqual(coordinator.server?.readyHandlerCallCount, 1)
        XCTAssertEqual(coordinator.server?.acknowledgedCount, 1)
    }

    func testUnreadyPeerWithBufferedByteDoesNotBusyWakeServer() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let coordinator = try primaryCoordinator(in: temporaryDirectory)
        coordinator.startReopenLoop()
        defer { coordinator.beginShutdown(); coordinator.close() }
        guard let counters = coordinator.server?.debugCounters else {
            XCTFail("Primary server is missing")
            return
        }
        counters.reset()

        let socketPath = coordinator.paths.socketPath
        let sent = DispatchSemaphore(value: 0)
        let acknowledged = DispatchSemaphore(value: 0)
        let state = RawServerState()

        DispatchQueue.global(qos: .userInitiated).async {
            let descriptor = connectRawClient(at: socketPath)
            guard descriptor >= 0 else {
                state.error = "connect failed"
                sent.signal()
                acknowledged.signal()
                return
            }
            defer { close(descriptor) }
            var request = ReopenClient.requestByte
            let wrote = withUnsafePointer(to: &request) { send(descriptor, $0, 1, 0) }
            guard wrote == 1 else {
                state.error = "send failed"
                sent.signal()
                acknowledged.signal()
                return
            }
            sent.signal()

            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = withUnsafeMutablePointer(to: &item) { poll($0, 1, 1_000) }
            guard ready > 0 else {
                state.error = "ack timed out"
                acknowledged.signal()
                return
            }
            var reply: UInt8 = 0
            let received = withUnsafeMutablePointer(to: &reply) {
                recv(descriptor, $0, 1, 0)
            }
            if received == 1 && reply == ReopenClient.acknowledgementByte {
                acknowledged.signal()
            } else {
                state.error = "ack failed"
                acknowledged.signal()
            }
        }

        XCTAssertTrue(waitForSignal(sent, timeout: 1))
        pumpMainRunLoop(for: 0.3)
        let wakeCount = counters.pumps
        print("Unready peer pump wakeups in 300 ms: \(wakeCount)")
        XCTAssertLessThanOrEqual(
            wakeCount,
            3,
            "Observed \(wakeCount) pump wakeups in 300 ms before readiness"
        )

        var reopenCalls = 0
        coordinator.markReady { reopenCalls += 1 }
        XCTAssertTrue(waitForSignal(acknowledged, timeout: 1))
        XCTAssertNil(state.error)
        XCTAssertEqual(reopenCalls, 1)
        XCTAssertEqual(coordinator.server?.readyHandlerCallCount, 1)
        XCTAssertEqual(coordinator.server?.acknowledgedCount, 1)
        XCTAssertEqual(coordinator.server?.pendingCount, 0)
    }

    func testUnreadyPeerHangupIsRemovedWithoutReadiness() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let coordinator = try primaryCoordinator(in: temporaryDirectory)
        coordinator.startReopenLoop()
        defer { coordinator.beginShutdown(); coordinator.close() }
        guard let counters = coordinator.server?.debugCounters else {
            XCTFail("Primary server is missing")
            return
        }
        counters.reset()

        let socketPath = coordinator.paths.socketPath
        let connected = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)
        let state = RawServerState()
        DispatchQueue.global(qos: .userInitiated).async {
            let descriptor = connectRawClient(at: socketPath)
            guard descriptor >= 0 else {
                state.error = "connect failed"
                connected.signal()
                closed.signal()
                return
            }
            connected.signal()
            Thread.sleep(forTimeInterval: 0.05)
            close(descriptor)
            closed.signal()
        }

        XCTAssertTrue(waitForSignal(connected, timeout: 1))
        XCTAssertTrue(waitForSignal(closed, timeout: 1))
        let deadline = Date().addingTimeInterval(1)
        while ((coordinator.server?.pendingCount ?? 0) != 0
                || counters.peerCancels == 0)
                && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertNil(state.error)
        XCTAssertEqual(coordinator.server?.pendingCount, 0)
        XCTAssertGreaterThanOrEqual(counters.peerCancels, 1)
        XCTAssertEqual(coordinator.server?.readyHandlerCallCount, 0)
    }

    func testRealCoordinatorsSimultaneousLaunchHandOffOnceAfterSlowStartup() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let coordinators = [
            try SingleInstanceCoordinator(baseDirectory: temporaryDirectory),
            try SingleInstanceCoordinator(baseDirectory: temporaryDirectory),
        ]
        let results = IndexedClaimResultsBox()
        let start = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)

        for (index, coordinator) in coordinators.enumerated() {
            let claimant = coordinator.claimant
            DispatchQueue.global(qos: .userInitiated).async {
                start.wait()
                do {
                    results.append(index: index, result: .success(try claimant.acquireOrHandOff(
                        deadline: .after(milliseconds: SingleInstanceCoordinator.handoffDeadlineMilliseconds)
                    )))
                } catch {
                    results.append(index: index, result: .failure(error))
                }
                finished.signal()
            }
        }
        start.signal()
        start.signal()

        var primary: SingleInstanceCoordinator?
        let primaryDeadline = Date().addingTimeInterval(2)
        while primary == nil && Date() < primaryDeadline {
            for entry in results.values {
                if case .success(.primary) = entry.result { primary = coordinators[entry.index] }
            }
            if primary == nil {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        }
        XCTAssertNotNil(primary)
        guard let primary else { return }

        let installed = try primary.acquireOrHandOff(deadline: .after(milliseconds: 10))
        XCTAssertEqual(installed, .primary)
        primary.startReopenLoop()
        defer {
            primary.beginShutdown()
            primary.close()
            for coordinator in coordinators where coordinator !== primary {
                coordinator.claimant.lease.release()
            }
        }

        pumpMainRunLoop(for: 0.85)

        var reopenCalls = 0
        primary.markReady { reopenCalls += 1 }
        XCTAssertTrue(waitForSignal(finished, timeout: 4))
        XCTAssertTrue(waitForSignal(finished, timeout: 4))

        let entries = results.values
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.index)), Set(0..<2))
        let acquisitions = entries.compactMap { try? $0.result.get() }
        XCTAssertEqual(acquisitions.filter { $0 == .primary }.count, 1)
        XCTAssertEqual(acquisitions.filter { $0 == .secondary }.count, 1)
        XCTAssertEqual(reopenCalls, 1)
        XCTAssertEqual(primary.server?.readyHandlerCallCount, 1)
        for case .failure(let error) in entries.map(\.result) {
            XCTAssertFalse(
                String(describing: error).localizedCaseInsensitiveContains("insecure"),
                "A simultaneous launch must not report an insecure socket"
            )
        }
    }

    func testBoundSocketRemainsConnectableAfterRename() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let directory = (base as NSString).appendingPathComponent("dot-\(geteuid())")
        XCTAssertEqual(mkdir(directory, mode_t(0o700)), 0)
        let initial = (directory as NSString).appendingPathComponent("source.sock")
        let published = (directory as NSString).appendingPathComponent("reopen.sock")

        let descriptor = try makeBoundSocket(at: initial)
        defer { close(descriptor) }
        XCTAssertEqual(chmod(initial, 0o600), 0)
        XCTAssertEqual(listen(descriptor, 8), 0)
        XCTAssertEqual(rename(initial, published), 0)
        XCTAssertEqual(connectToUnixSocket(at: published), 0)
    }

    func testSymlinkedSocketDirectoryIsRejected() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let paths = try SingleInstancePaths(baseDirectory: base)
        let target = (base as NSString).appendingPathComponent("private-target")
        XCTAssertEqual(mkdir(target, mode_t(0o700)), 0)
        try FileManager.default.removeItem(atPath: paths.directoryPath)
        try FileManager.default.createSymbolicLink(
            atPath: paths.directoryPath,
            withDestinationPath: target
        )

        XCTAssertThrowsError(try ReopenClient.request(
            socketPath: paths.socketPath,
            deadline: .after(milliseconds: 50)
        )) { error in
            XCTAssertTrue(String(describing: error).localizedCaseInsensitiveContains("socket"))
        }
        XCTAssertThrowsError(try ReopenServer(socketPath: paths.socketPath)) { error in
            XCTAssertTrue(String(describing: error).localizedCaseInsensitiveContains("socket"))
        }
    }

    func testSymlinkedSocketIsRejectedByClientAndServer() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let paths = try SingleInstancePaths(baseDirectory: temporaryDirectory)
        let target = paths.socketPath + ".target"
        try Data("socket target".utf8).write(to: URL(fileURLWithPath: target))
        try FileManager.default.createSymbolicLink(
            atPath: paths.socketPath,
            withDestinationPath: target
        )

        XCTAssertThrowsError(try ReopenClient.request(
            socketPath: paths.socketPath,
            deadline: .after(milliseconds: 50)
        )) { error in
            XCTAssertTrue(String(describing: error).localizedCaseInsensitiveContains("socket"))
        }
        XCTAssertThrowsError(try ReopenServer(socketPath: paths.socketPath)) { error in
            XCTAssertTrue(String(describing: error).localizedCaseInsensitiveContains("socket"))
        }
    }

    func testServerDeinitClosesSocketWithoutBeginShutdown() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let paths = try SingleInstancePaths(baseDirectory: temporaryDirectory)
        weak var weakServer: ReopenServer?
        do {
            let server = try ReopenServer(socketPath: paths.socketPath)
            weakServer = server
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.socketPath))
        }
        XCTAssertNil(weakServer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.socketPath))
    }

    func testDefaultPathsUseApplicationSupport() throws {
        SingleInstancePaths.setTestBaseDirectory(nil)
        XCTAssertEqual(SingleInstancePaths.defaultBaseDirectory, DotConfig.directoryURL().path)

        let injected = try makeInjectedSupportDirectory()
        defer { try? FileManager.default.removeItem(atPath: injected.base) }
        SingleInstancePaths.setTestBaseDirectory(injected.support)
        defer { SingleInstancePaths.setTestBaseDirectory(nil) }

        let paths = try SingleInstancePaths()
        XCTAssertEqual((paths.directoryPath as NSString).deletingLastPathComponent, injected.support)
        XCTAssertTrue(paths.socketPath.hasPrefix(injected.support + "/"))
        XCTAssertTrue(UnixSocketPath.fits(paths.socketPath))
    }

    func testShutdownDoesNotUnlinkReplacementSocket() throws {
        let injected = try makeInjectedSupportDirectory()
        defer { try? FileManager.default.removeItem(atPath: injected.base) }
        SingleInstancePaths.setTestBaseDirectory(injected.support)
        defer { SingleInstancePaths.setTestBaseDirectory(nil) }

        let primary = try SingleInstanceCoordinator()
        XCTAssertEqual(
            try primary.acquireOrHandOff(
                deadline: .after(milliseconds: SingleInstanceCoordinator.handoffDeadlineMilliseconds)
            ),
            .primary
        )
        let paths = primary.paths
        try FileManager.default.removeItem(atPath: paths.lockPath)
        try FileManager.default.removeItem(atPath: paths.socketPath)

        let replacement = try ReopenServer(socketPath: paths.socketPath)
        let replacementIdentity = try fileIdentity(paths.socketPath)
        primary.beginShutdown()

        let after = try? fileIdentity(paths.socketPath)
        XCTAssertEqual(after?.dev, replacementIdentity.dev)
        XCTAssertEqual(after?.inode, replacementIdentity.inode)
        replacement.beginShutdown()
        primary.close()
    }

    func testHandoffBudgetAllowsSlowPrimary() throws {
        XCTAssertEqual(SingleInstanceCoordinator.handoffDeadlineMilliseconds, 10_000)
        XCTAssertEqual(ReopenServer.defaultPendingLifetimeMilliseconds, 12_000)

        let injected = try makeInjectedSupportDirectory()
        defer { try? FileManager.default.removeItem(atPath: injected.base) }
        SingleInstancePaths.setTestBaseDirectory(injected.support)
        defer { SingleInstancePaths.setTestBaseDirectory(nil) }

        let primary = try SingleInstanceCoordinator()
        XCTAssertEqual(
            try primary.acquireOrHandOff(deadline: .after(milliseconds: 1_000)),
            .primary
        )
        primary.startReopenLoop()
        defer { primary.beginShutdown(); primary.close() }

        let contender = try SingleInstanceClaimant()
        let results = ClaimResultsBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                results.append(.success(try contender.acquireOrHandOff(
                    deadline: .after(milliseconds: 500)
                )))
            } catch {
                results.append(.failure(error))
            }
            finished.signal()
        }

        pumpMainRunLoop(for: 0.35)
        var reopenCalls = 0
        primary.markReady { reopenCalls += 1 }
        XCTAssertTrue(waitForSignal(finished, timeout: 1))
        XCTAssertEqual(results.values.compactMap { try? $0.get() }, [.secondary])
        XCTAssertEqual(reopenCalls, 1)
        XCTAssertEqual(primary.server?.acknowledgedCount, 1)
    }

    func testNineUnreadyPeersDoNotBusyWakeServer() throws {
        let injected = try makeInjectedSupportDirectory()
        defer { try? FileManager.default.removeItem(atPath: injected.base) }
        SingleInstancePaths.setTestBaseDirectory(injected.support)
        defer { SingleInstancePaths.setTestBaseDirectory(nil) }

        let coordinator = try SingleInstanceCoordinator()
        XCTAssertEqual(try coordinator.acquireOrHandOff(deadline: .after(milliseconds: 1_000)), .primary)
        coordinator.startReopenLoop()
        defer { coordinator.beginShutdown(); coordinator.close() }
        guard let counters = coordinator.server?.debugCounters else {
            XCTFail("Primary server is missing")
            return
        }
        counters.reset()

        var clients: [Int32] = []
        defer { for descriptor in clients { close(descriptor) } }
        for _ in 0..<8 {
            let descriptor = connectRawClient(at: coordinator.paths.socketPath)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            if descriptor >= 0 { clients.append(descriptor) }
        }
        XCTAssertTrue(waitForPendingCount(coordinator.server, minimum: 8, timeout: 1))
        counters.reset()
        let overflow = connectRawClient(at: coordinator.paths.socketPath)
        XCTAssertGreaterThanOrEqual(overflow, 0)
        if overflow >= 0 { clients.append(overflow) }
        pumpMainRunLoop(for: 0.3)
        let wakeCount = counters.pumps
        print("Nine unready peer pump wakeups in 300 ms: \(wakeCount)")
        XCTAssertLessThanOrEqual(wakeCount, 3)
    }

    func testBufferedPeerExtraBytesAreDrainedAndClosed() throws {
        let injected = try makeInjectedSupportDirectory()
        defer { try? FileManager.default.removeItem(atPath: injected.base) }
        SingleInstancePaths.setTestBaseDirectory(injected.support)
        defer { SingleInstancePaths.setTestBaseDirectory(nil) }

        let coordinator = try SingleInstanceCoordinator()
        XCTAssertEqual(try coordinator.acquireOrHandOff(deadline: .after(milliseconds: 1_000)), .primary)
        coordinator.startReopenLoop()
        defer { coordinator.beginShutdown(); coordinator.close() }
        guard let counters = coordinator.server?.debugCounters else {
            XCTFail("Primary server is missing")
            return
        }
        counters.reset()

        let sent = DispatchSemaphore(value: 0)
        let state = RawServerState()
        let socketPath = coordinator.paths.socketPath
        DispatchQueue.global(qos: .userInitiated).async {
            let descriptor = connectRawClient(at: socketPath)
            guard descriptor >= 0 else {
                state.error = "connect failed"
                sent.signal()
                return
            }
            var payload = [ReopenClient.requestByte]
            payload.append(contentsOf: Array(repeating: 0x58, count: 32))
            let wrote = payload.withUnsafeBytes { bytes in
                send(descriptor, bytes.baseAddress!, bytes.count, 0)
            }
            if wrote != payload.count { state.error = "send failed" }
            sent.signal()
        }

        XCTAssertTrue(waitForSignal(sent, timeout: 1))
        pumpMainRunLoop(for: 0.3)
        let wakeCount = counters.pumps
        print("Buffered peer extra-byte pump wakeups in 300 ms: \(wakeCount)")
        XCTAssertLessThanOrEqual(wakeCount, 3)

        let deadline = Date().addingTimeInterval(1)
        while (coordinator.server?.pendingCount ?? 0) != 0 && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertNil(state.error)
        XCTAssertEqual(coordinator.server?.pendingCount, 0)
        XCTAssertGreaterThanOrEqual(counters.peerCancels, 1)
        for descriptor in counters.acceptedDescriptors {
            XCTAssertEqual(counters.closeCount(for: descriptor), 1)
        }
    }

    func testIdleUnreadyPeerExpiresWithoutOtherActivity() throws {
        let injected = try makeInjectedSupportDirectory()
        defer { try? FileManager.default.removeItem(atPath: injected.base) }
        SingleInstancePaths.setTestBaseDirectory(injected.support)
        defer { SingleInstancePaths.setTestBaseDirectory(nil) }

        let paths = try SingleInstancePaths()
        let server = try ReopenServer(
            socketPath: paths.socketPath,
            pendingLifetimeMilliseconds: 150
        )
        server.startTimer()
        defer { server.beginShutdown() }
        server.debugCounters.reset()

        let descriptor = connectRawClient(at: paths.socketPath)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { close(descriptor) } }
        XCTAssertTrue(waitForPendingCount(server, minimum: 1, timeout: 1))
        pumpMainRunLoop(for: 0.5)

        XCTAssertEqual(server.pendingCount, 0)
        XCTAssertGreaterThanOrEqual(server.debugCounters.peerCancels, 1)
        for accepted in server.debugCounters.acceptedDescriptors {
            XCTAssertEqual(server.debugCounters.closeCount(for: accepted), 1)
        }
    }

    func testWrongDirectoryModeIsRejected() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let paths = try SingleInstancePaths(baseDirectory: temporaryDirectory)
        XCTAssertEqual(chmod(paths.directoryPath, 0o777), 0)
        defer { _ = chmod(paths.directoryPath, 0o700) }

        XCTAssertThrowsError(try SingleInstancePaths(baseDirectory: temporaryDirectory)) { error in
            XCTAssertTrue(String(describing: error).localizedCaseInsensitiveContains("directory"))
        }
    }

    func testWrongLockModeIsRejected() throws {
        defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }
        let paths = try SingleInstancePaths(baseDirectory: temporaryDirectory)
        XCTAssertEqual(chmod(paths.lockPath, 0o644), 0)
        defer { _ = chmod(paths.lockPath, 0o600) }

        XCTAssertThrowsError(try SingleInstancePaths(baseDirectory: temporaryDirectory)) { error in
            XCTAssertTrue(String(describing: error).localizedCaseInsensitiveContains("lock"))
        }
    }
}

@MainActor
final class SingleInstanceBypassTests: XCTestCase {
    func testXCTestHostBypassesCoordinator() {
        XCTAssertTrue(SingleInstance.bypassesCoordinator(
            environment: [:],
            arguments: ["Dot"],
            hasXCTestClass: true
        ))
    }

    func testDualTriggerBypassesCoordinator() {
        let key = DotMigration.legacyEnvironmentPrefix + "TEST_TRIGGER"
        XCTAssertTrue(SingleInstance.bypassesCoordinator(
            environment: [key: "/tmp/trigger"],
            arguments: ["Dot", "--allow-test-trigger"],
            hasXCTestClass: false
        ))
    }

    func testOneShotRenderModesBypassCoordinator() {
        let arguments = [
            MenuDump.argument,
            HUDPreview.argument,
            DemoRender.argument,
            UIPreview.argument,
            IconRender.argument,
        ]
        for argument in arguments {
            XCTAssertTrue(
                SingleInstance.bypassesCoordinator(
                    environment: [:],
                    arguments: ["Dot", argument, "/tmp/dot-single-instance-render"],
                    hasXCTestClass: false
                ),
                "\(argument) must not create a single-instance lease"
            )
        }
    }

    func testNormalLaunchDoesNotBypassCoordinator() {
        XCTAssertFalse(SingleInstance.bypassesCoordinator(
            environment: [:],
            arguments: ["Dot"],
            hasXCTestClass: false
        ))
    }
}
