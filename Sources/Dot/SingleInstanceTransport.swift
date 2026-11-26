import Darwin
import Foundation

enum UnixSocketPath {
    static let maximumBytes = MemoryLayout<sockaddr_un>.size
        - MemoryLayout<sockaddr_un>.offset(of: \.sun_path)!

    static func fits(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count < maximumBytes
    }
}

private struct SocketIdentity {
    let dev: UInt64
    let inode: UInt64
}

private func boundSocketIdentity(at path: String) throws -> SocketIdentity {
    var information = stat()
    guard lstat(path, &information) == 0 else {
        throw SingleInstanceFailure.socket(posixText(errno, "lstat(published socket)"))
    }
    guard information.st_mode & S_IFMT != S_IFLNK,
          information.st_mode & S_IFMT == S_IFSOCK,
          information.st_uid == geteuid() else {
        throw SingleInstanceFailure.insecureSocket("reopen socket has unsafe metadata")
    }
    return SocketIdentity(
        dev: UInt64(information.st_dev),
        inode: UInt64(information.st_ino)
    )
}

enum ImmediateByteResult {
    case byte(UInt8)
    case unavailable
    case closed
    case failed(String)
}

private enum DeadlineByteResult {
    case byte(UInt8)
    case closed
    case timedOut
}

enum NonblockingConnectResult {
    case connected
    case transient
    case failed(String)
}

enum ReopenRequestResult: Equatable {
    case acknowledged
    case transient
    case timedOut
}

private enum EndpointCheck {
    case valid
    case missing
    case transientMode
    case invalid(String)
}

private func posixText(_ code: Int32, _ operation: String) -> String {
    "\(operation) failed (\(code)): \(String(cString: strerror(code)))"
}

private func isTransientConnectError(_ code: Int32) -> Bool {
    code == ENOENT || code == ECONNREFUSED || code == EAGAIN
        || code == EINTR || code == EALREADY || code == ETIMEDOUT
}

private func setCloseOnExec(_ descriptor: Int32) throws {
    let flags = fcntl(descriptor, F_GETFD)
    guard flags != -1 else { throw SingleInstanceFailure.socket(posixText(errno, "F_GETFD")) }
    guard fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) != -1 else {
        throw SingleInstanceFailure.socket(posixText(errno, "F_SETFD"))
    }
}

private func setNonBlocking(_ descriptor: Int32) throws {
    let flags = fcntl(descriptor, F_GETFL)
    guard flags != -1 else { throw SingleInstanceFailure.socket(posixText(errno, "F_GETFL")) }
    guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
        throw SingleInstanceFailure.socket(posixText(errno, "F_SETFL"))
    }
}

private func setNoSIGPIPE(_ descriptor: Int32) throws {
    var enabled: Int32 = 1
    let result = withUnsafePointer(to: &enabled) { pointer in
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            pointer,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }
    guard result == 0 else { throw SingleInstanceFailure.socket(posixText(errno, "SO_NOSIGPIPE")) }
}

private func makeSocketDescriptor() throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw SingleInstanceFailure.socket(posixText(errno, "socket")) }
    do {
        try setCloseOnExec(descriptor)
        try setNonBlocking(descriptor)
        try setNoSIGPIPE(descriptor)
        return descriptor
    } catch {
        close(descriptor)
        throw error
    }
}

private func socketAddress(for path: String) throws -> sockaddr_un {
    guard UnixSocketPath.fits(path) else { throw SingleInstanceFailure.socket("reopen socket path is too long") }
    let bytes = Array(path.utf8) + [0]
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    _ = bytes.withUnsafeBytes { source in
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            memcpy(destination.baseAddress, source.baseAddress, bytes.count)
        }
    }
    return address
}

private func withSocketAddress<T>(
    _ address: inout sockaddr_un,
    _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
) -> T {
    withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
            body(socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func checkPrivateParent(for path: String) throws {
    let parent = (path as NSString).deletingLastPathComponent
    var information = stat()
    guard lstat(parent, &information) == 0 else {
        throw SingleInstanceFailure.socket(posixText(errno, "lstat(socket directory)"))
    }
    guard information.st_mode & S_IFMT != S_IFLNK,
          information.st_mode & S_IFMT == S_IFDIR,
          information.st_uid == geteuid(),
          information.st_mode & 0o777 == 0o700 else {
        throw SingleInstanceFailure.insecureSocket("expected an owned 0700 socket directory")
    }
}

private func checkClientEndpoint(
    _ path: String,
    allowTransientLooseMode: Bool
) throws -> EndpointCheck {
    guard path.hasPrefix("/"), UnixSocketPath.fits(path) else {
        throw SingleInstanceFailure.insecureSocket("reopen socket path is not a short absolute path")
    }
    try checkPrivateParent(for: path)

    var information = stat()
    guard lstat(path, &information) == 0 else {
        if errno == ENOENT { return .missing }
        return .invalid(posixText(errno, "lstat(socket)"))
    }
    guard information.st_mode & S_IFMT != S_IFLNK,
          information.st_mode & S_IFMT == S_IFSOCK,
          information.st_uid == geteuid() else {
        return .invalid("reopen socket has unsafe metadata")
    }
    let mode = information.st_mode & 0o777
    if mode == 0o600 { return .valid }
    if allowTransientLooseMode, mode & ~mode_t(0o600) != 0 { return .transientMode }
    return .invalid("reopen socket has unsafe metadata")
}

private func peerIsCurrentUser(_ descriptor: Int32) throws -> Bool {
    var peerUID = uid_t()
    var peerGID = gid_t()
    guard getpeereid(descriptor, &peerUID, &peerGID) == 0 else {
        throw SingleInstanceFailure.handshake(posixText(errno, "getpeereid"))
    }
    return peerUID == geteuid()
}

private func removeOwnedSocketIfPresent(
    at path: String,
    matching identity: SocketIdentity? = nil
) {
    var information = stat()
    guard lstat(path, &information) == 0 else { return }
    guard information.st_mode & S_IFMT != S_IFLNK,
          information.st_mode & S_IFMT == S_IFSOCK,
          information.st_uid == geteuid() else { return }
    if let identity {
        guard UInt64(information.st_dev) == identity.dev,
              UInt64(information.st_ino) == identity.inode else { return }
    }
    _ = unlink(path)
}

private func validateSocketReplacement(at path: String) throws {
    var information = stat()
    guard lstat(path, &information) == 0 else {
        if errno == ENOENT { return }
        throw SingleInstanceFailure.socket(posixText(errno, "lstat(socket)"))
    }
    guard information.st_mode & S_IFMT != S_IFLNK else {
        throw SingleInstanceFailure.insecureSocket("reopen socket is a symbolic link")
    }
    guard information.st_mode & S_IFMT == S_IFSOCK,
          information.st_uid == geteuid() else {
        throw SingleInstanceFailure.insecureSocket("existing socket entry is not owned by this user")
    }
}

private func temporarySocketPath(for path: String) throws -> String {
    let directory = (path as NSString).deletingLastPathComponent
    for attempt in 0..<128 {
        let name = attempt == 0 ? ".\(getpid())" : ".\(getpid()).\(attempt)"
        let candidate = (directory as NSString).appendingPathComponent(name)
        guard UnixSocketPath.fits(candidate) else { continue }
        var information = stat()
        if lstat(candidate, &information) != 0 && errno == ENOENT { return candidate }
    }
    throw SingleInstanceFailure.socket("no temporary socket path is available")
}

private func pollDescriptor(
    _ descriptor: Int32,
    events: Int16,
    deadline: MonotonicDeadline
) throws -> Int16 {
    var item = pollfd(fd: descriptor, events: events, revents: 0)
    let result = withUnsafeMutablePointer(to: &item) { pointer in
        poll(pointer, 1, deadline.remainingMilliseconds)
    }
    if result < 0 {
        if errno == EINTR { return 0 }
        throw SingleInstanceFailure.handshake(posixText(errno, "poll"))
    }
    return result == 0 ? 0 : item.revents
}

private func connectWithoutBlocking(
    _ descriptor: Int32,
    to path: String,
    deadline: MonotonicDeadline
) throws -> NonblockingConnectResult {
    var address = try socketAddress(for: path)
    let result = withSocketAddress(&address) { pointer, length in
        connect(descriptor, pointer, length)
    }
    if result == 0 { return .connected }
    let error = errno
    if error == EAGAIN { return .transient }
    guard error == EINPROGRESS || error == EALREADY || error == EINTR else {
        return isTransientConnectError(error) ? .transient : .failed(posixText(error, "connect"))
    }

    while !deadline.isExpired {
        let events = try pollDescriptor(
            descriptor,
            events: Int16(POLLOUT | POLLIN),
            deadline: deadline
        )
        if events == 0 { continue }
        if events & Int16(POLLNVAL) != 0 { return .failed("connect poll reported an invalid descriptor") }

        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let lookup = withUnsafeMutablePointer(to: &socketError) { pointer in
            getsockopt(descriptor, SOL_SOCKET, SO_ERROR, pointer, &length)
        }
        guard lookup == 0 else { return .failed(posixText(errno, "getsockopt(SO_ERROR)")) }
        if socketError == 0 { return .connected }
        if isTransientConnectError(socketError) { return .transient }
        return .failed(posixText(socketError, "connect"))
    }
    return .transient
}

private func sendByte(
    _ value: UInt8,
    on descriptor: Int32,
    deadline: MonotonicDeadline
) throws -> Bool {
    var byte = value
    while !deadline.isExpired {
        let sent = withUnsafePointer(to: &byte) { pointer in
            send(descriptor, pointer, 1, 0)
        }
        if sent == 1 { return true }
        if sent >= 0 { return false }
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            _ = try pollDescriptor(descriptor, events: Int16(POLLOUT), deadline: deadline)
            continue
        }
        return false
    }
    return false
}

private func readByte(
    from descriptor: Int32,
    deadline: MonotonicDeadline
) throws -> DeadlineByteResult {
    while !deadline.isExpired {
        let events = try pollDescriptor(descriptor, events: Int16(POLLIN), deadline: deadline)
        if events == 0 { continue }
        if events & Int16(POLLNVAL) != 0 { return .closed }
        var byte: UInt8 = 0
        let received = withUnsafeMutablePointer(to: &byte) { pointer in
            recv(descriptor, pointer, 1, 0)
        }
        if received == 1 { return .byte(byte) }
        if received == 0 { return .closed }
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
        return .closed
    }
    return .timedOut
}

private func readAvailableByte(from descriptor: Int32) -> ImmediateByteResult {
    var byte: UInt8 = 0
    let received = withUnsafeMutablePointer(to: &byte) { pointer in
        recv(descriptor, pointer, 1, 0)
    }
    if received == 1 { return .byte(byte) }
    if received == 0 { return .closed }
    if errno == EINTR { return .unavailable }
    if errno == EAGAIN || errno == EWOULDBLOCK { return .unavailable }
    return .failed(posixText(errno, "recv"))
}

struct ReopenClient {
    static let requestByte: UInt8 = 0x52
    static let acknowledgementByte: UInt8 = 0x41

    /// One bounded attempt. The connect deadline covers finding the socket;
    /// once connected, the response deadline is the whole hand-off budget so a
    /// slow primary never causes another connection and another reopen.
    static func request(
        socketPath: String,
        deadline: MonotonicDeadline,
        responseDeadline: MonotonicDeadline? = nil,
        allowTransientLooseMode: Bool = false,
        didSend: (() -> Void)? = nil
    ) throws -> ReopenRequestResult {
        switch try checkClientEndpoint(
            socketPath,
            allowTransientLooseMode: allowTransientLooseMode
        ) {
        case .missing, .transientMode:
            return .transient
        case .invalid(let detail):
            throw SingleInstanceFailure.insecureSocket(detail)
        case .valid:
            break
        }

        let descriptor = try makeSocketDescriptor()
        defer { close(descriptor) }
        let responseDeadline = responseDeadline ?? deadline

        switch try connectWithoutBlocking(descriptor, to: socketPath, deadline: deadline) {
        case .connected:
            guard try peerIsCurrentUser(descriptor) else {
                throw SingleInstanceFailure.insecureSocket("reopen peer is not the same user")
            }
            guard try sendByte(requestByte, on: descriptor, deadline: responseDeadline) else {
                return .transient
            }
            didSend?()
            switch try readByte(from: descriptor, deadline: responseDeadline) {
            case .byte(let reply) where reply == acknowledgementByte:
                return .acknowledged
            case .byte:
                return .transient
            case .closed:
                return .transient
            case .timedOut:
                return .timedOut
            }
        case .transient:
            return .transient
        case .failed(let message):
            throw SingleInstanceFailure.handshake(message)
        }
    }
}

#if DEBUG
final class ReopenServerDebugCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var pumpCount = 0
    private var peerCancelCount = 0
    private var accepted: [Int32] = []
    private var closeCounts: [Int32: Int] = [:]

    func reset() {
        lock.lock()
        pumpCount = 0
        peerCancelCount = 0
        accepted.removeAll()
        closeCounts.removeAll()
        lock.unlock()
    }

    func notePeerAccept(_ descriptor: Int32) {
        lock.lock()
        accepted.append(descriptor)
        lock.unlock()
    }

    func noteDescriptorClose(_ descriptor: Int32) {
        lock.lock()
        closeCounts[descriptor, default: 0] += 1
        lock.unlock()
    }

    func notePump() {
        lock.lock()
        pumpCount += 1
        lock.unlock()
    }

    func notePeerCancel() {
        lock.lock()
        peerCancelCount += 1
        lock.unlock()
    }

    var pumps: Int {
        lock.lock()
        defer { lock.unlock() }
        return pumpCount
    }

    var peerCancels: Int {
        lock.lock()
        defer { lock.unlock() }
        return peerCancelCount
    }

    var acceptedDescriptors: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return accepted
    }

    func closeCount(for descriptor: Int32) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return closeCounts[descriptor] ?? 0
    }
}
#endif

@MainActor
final class ReopenServer: NSObject {
    private struct PendingRequest {
        let descriptor: Int32
        let expires: MonotonicDeadline
        let source: DispatchSourceRead?
        let timer: DispatchSourceTimer?
        var bufferedRequest: UInt8?
    }

    private static let backlog: Int32 = 8
    private static let maximumPending = 8
    private static let maximumExtraBytes = 16
    static let defaultPendingLifetimeMilliseconds: UInt64 = 12_000

    private let socketPath: String
    private let pendingLifetimeMilliseconds: UInt64
    private var socketIdentity: SocketIdentity?
    private var listeningDescriptor: Int32?
    private var listeningSource: DispatchSourceRead?
    private var pending: [PendingRequest] = []
    private var readyHandler: (@MainActor () -> Void)?

    private(set) var acknowledgedCount = 0
    private(set) var readyHandlerCallCount = 0
    private(set) var isShuttingDown = false

#if DEBUG
    let debugCounters = ReopenServerDebugCounters()
#endif

    var pendingCount: Int { pending.count }

    init(
        socketPath: String,
        beforeListen: (() throws -> Void)? = nil,
        pendingLifetimeMilliseconds: UInt64? = nil
    ) throws {
        self.socketPath = socketPath
        self.pendingLifetimeMilliseconds = pendingLifetimeMilliseconds
            ?? Self.defaultPendingLifetimeMilliseconds
        self.socketIdentity = nil
        let descriptor = try Self.makeListeningDescriptor(
            at: socketPath,
            beforeListen: beforeListen
        )
        do {
            self.socketIdentity = try boundSocketIdentity(at: socketPath)
        } catch {
            close(descriptor)
            removeOwnedSocketIfPresent(at: socketPath)
            throw error
        }
        self.listeningDescriptor = descriptor
    }

    /// The listening socket wakes this source only when a client connects,
    /// so an idle primary has no repeating main-thread work.
    func startTimer() {
        guard listeningSource == nil, !isShuttingDown, let listeningDescriptor else { return }
        let descriptor = listeningDescriptor
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.pump() }
        }
        // Once the source exists, its cancel handler owns the descriptor.
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        listeningSource = source
    }

    private func makePeerSource(for descriptor: Int32) -> DispatchSourceRead? {
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.pump() }
        }
#if DEBUG
        let counters = debugCounters
        counters.notePeerAccept(descriptor)
        source.setCancelHandler {
            counters.notePeerCancel()
            counters.noteDescriptorClose(descriptor)
            Darwin.close(descriptor)
        }
#else
        source.setCancelHandler { Darwin.close(descriptor) }
#endif
        source.resume()
        return source
    }

    private func makePeerTimer() -> DispatchSourceTimer? {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.pump() }
        }
        timer.schedule(
            deadline: .now() + Double(pendingLifetimeMilliseconds) / 1_000,
            leeway: .milliseconds(10)
        )
        timer.resume()
        return timer
    }

    private func drainExtraBytes(from descriptor: Int32) -> (closed: Bool, exceeded: Bool) {
        var byte: UInt8 = 0
        var extra = 0
        while extra <= Self.maximumExtraBytes {
            let received = withUnsafeMutablePointer(to: &byte) {
                recv(descriptor, $0, 1, 0)
            }
            if received == 1 {
                extra += 1
                if extra > Self.maximumExtraBytes { return (false, true) }
                continue
            }
            if received == 0 { return (true, false) }
            if errno == EINTR { continue }
            return (false, false)
        }
        return (false, true)
    }

    private func closePending(_ request: PendingRequest) {
        // Wake the client before the cancel handler runs on a later turn. The
        // descriptor itself is still closed by the source's cancel handler.
        _ = shutdown(request.descriptor, SHUT_WR)
        request.timer?.cancel()
        if let source = request.source {
            source.cancel()
        } else {
            close(request.descriptor)
        }
    }

    func markReady(_ handler: @escaping @MainActor () -> Void) {
        guard !isShuttingDown else { return }
        readyHandler = handler
        pump()
    }

    deinit {
        guard !isShuttingDown else { return }
        if let listeningSource {
            listeningSource.cancel()
        } else if let listeningDescriptor {
            close(listeningDescriptor)
        }
        for request in pending {
            _ = shutdown(request.descriptor, SHUT_WR)
            request.timer?.cancel()
            if let source = request.source {
                source.cancel()
            } else {
                close(request.descriptor)
            }
        }
        removeOwnedSocketIfPresent(at: socketPath, matching: socketIdentity)
    }

    func pump() {
#if DEBUG
        debugCounters.notePump()
#endif
        guard !isShuttingDown, listeningDescriptor != nil else { return }
        pruneDisconnected()
        acceptConnections()
        serviceRequests()
    }

    func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        if let listeningSource {
            listeningSource.cancel()
            self.listeningSource = nil
        } else if let listeningDescriptor {
            close(listeningDescriptor)
        }
        self.listeningDescriptor = nil
        readyHandler = nil

        removeOwnedSocketIfPresent(at: socketPath, matching: socketIdentity)
        for request in pending {
            closePending(request)
        }
        pending.removeAll()
    }

    private static func makeListeningDescriptor(
        at path: String,
        beforeListen: (() throws -> Void)?
    ) throws -> Int32 {
        guard UnixSocketPath.fits(path) else {
            throw SingleInstanceFailure.socket("reopen socket path is too long")
        }
        try checkPrivateParent(for: path)
        try validateSocketReplacement(at: path)

        // A Darwin bind creates the path with the umask-derived mode, so a
        // client polling reopen.sock could see it before chmod(0600). Bind a
        // private temporary name, secure it there, then publish with rename so
        // the final path is never observable with loose permissions.
        let temporaryPath = try temporarySocketPath(for: path)
        let descriptor = try makeSocketDescriptor()
        var published = false
        do {
            var address = try socketAddress(for: temporaryPath)
            let bound = withSocketAddress(&address) { pointer, length in
                Darwin.bind(descriptor, pointer, length)
            }
            guard bound == 0 else { throw SingleInstanceFailure.socket(posixText(errno, "bind")) }
            guard chmod(temporaryPath, 0o600) == 0 else {
                throw SingleInstanceFailure.socket(posixText(errno, "chmod(socket)"))
            }
            var information = stat()
            guard lstat(temporaryPath, &information) == 0 else {
                throw SingleInstanceFailure.socket(posixText(errno, "lstat(bound socket)"))
            }
            guard information.st_mode & S_IFMT == S_IFSOCK,
                  information.st_uid == geteuid(),
                  information.st_mode & 0o777 == 0o600 else {
                throw SingleInstanceFailure.insecureSocket("reopen socket has unsafe metadata")
            }
            try beforeListen?()
            guard listen(descriptor, backlog) == 0 else {
                throw SingleInstanceFailure.socket(posixText(errno, "listen"))
            }
            guard rename(temporaryPath, path) == 0 else {
                throw SingleInstanceFailure.socket(posixText(errno, "rename(socket)"))
            }
            published = true
            guard lstat(path, &information) == 0 else {
                throw SingleInstanceFailure.socket(posixText(errno, "lstat(published socket)"))
            }
            guard information.st_mode & S_IFMT == S_IFSOCK,
                  information.st_uid == geteuid(),
                  information.st_mode & 0o777 == 0o600 else {
                throw SingleInstanceFailure.insecureSocket("reopen socket has unsafe metadata")
            }
            return descriptor
        } catch {
            close(descriptor)
            if !published { removeOwnedSocketIfPresent(at: temporaryPath) }
            throw error
        }
    }

    /// A client that timed out and closed still leaves its request byte in the
    /// kernel buffer. Poll and peek first so its reopen is never delivered.
    private func peerIsLive(_ descriptor: Int32) -> Bool {
        var item = pollfd(fd: descriptor, events: 0, revents: 0)
        let polled = withUnsafeMutablePointer(to: &item) { poll($0, 1, 0) }
        guard polled >= 0 else { return false }
        if item.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return false }

        var probe: UInt8 = 0
        while true {
            let received = withUnsafeMutablePointer(to: &probe) {
                recv(descriptor, $0, 1, Int32(MSG_PEEK))
            }
            if received > 0 { return true }
            if received == 0 { return false }
            if errno == EINTR { continue }
            return errno == EAGAIN || errno == EWOULDBLOCK
        }
    }

    private func pruneDisconnected() {
        let now = MonotonicDeadline.nowNanoseconds
        var retained: [PendingRequest] = []
        for request in pending {
            if request.expires.isExpired(at: now) || !peerIsLive(request.descriptor) {
                closePending(request)
            } else {
                retained.append(request)
            }
        }
        pending = retained
    }

    private func acceptConnections() {
        guard let listeningDescriptor else { return }
        if pending.count >= Self.maximumPending {
            while true {
                let descriptor = accept(listeningDescriptor, nil, nil)
                if descriptor < 0 {
                    if errno == EINTR { continue }
                    return
                }
                close(descriptor)
            }
        }
        while pending.count < Self.maximumPending {
            let descriptor = accept(listeningDescriptor, nil, nil)
            if descriptor < 0 {
                if errno == EINTR { continue }
                return
            }
            do {
                try setCloseOnExec(descriptor)
                try setNonBlocking(descriptor)
                try setNoSIGPIPE(descriptor)
                guard try peerIsCurrentUser(descriptor), peerIsLive(descriptor) else {
                    close(descriptor)
                    continue
                }
                guard let source = makePeerSource(for: descriptor) else {
                    close(descriptor)
                    continue
                }
                guard let timer = makePeerTimer() else {
                    source.cancel()
                    continue
                }
                pending.append(PendingRequest(
                    descriptor: descriptor,
                    expires: .after(milliseconds: pendingLifetimeMilliseconds),
                    source: source,
                    timer: timer,
                    bufferedRequest: nil
                ))
            } catch {
                close(descriptor)
            }
        }
    }

    private func serviceRequests() {
        guard !isShuttingDown, !pending.isEmpty else { return }
        let isReady = readyHandler != nil
        let requests = pending
        pending.removeAll()
        var retained: [PendingRequest] = []
        var didReopen = false

        for var request in requests {
            if isShuttingDown || !peerIsLive(request.descriptor) {
                closePending(request)
                continue
            }
            if !isReady, request.bufferedRequest != nil {
                let drained = drainExtraBytes(from: request.descriptor)
                if drained.closed || drained.exceeded {
                    closePending(request)
                } else {
                    retained.append(request)
                }
                continue
            }
            let incoming: ImmediateByteResult
            if let buffered = request.bufferedRequest {
                incoming = .byte(buffered)
            } else {
                incoming = readAvailableByte(from: request.descriptor)
            }
            switch incoming {
            case .byte(let byte) where byte == ReopenClient.requestByte:
                guard peerIsLive(request.descriptor) else {
                    closePending(request)
                    continue
                }
                if !isReady {
                    // Consume the byte and drain anything already queued behind
                    // it so the level-triggered source has no readable data.
                    request.bufferedRequest = byte
                    let drained = drainExtraBytes(from: request.descriptor)
                    if drained.closed || drained.exceeded {
                        closePending(request)
                    } else {
                        retained.append(request)
                    }
                    continue
                }
                if !didReopen {
                    readyHandler?()
                    readyHandlerCallCount += 1
                    didReopen = true
                }
                if isShuttingDown {
                    closePending(request)
                    continue
                }
                if (try? sendByte(
                    ReopenClient.acknowledgementByte,
                    on: request.descriptor,
                    deadline: .after(milliseconds: 100)
                )) == true {
                    acknowledgedCount += 1
                }
                closePending(request)
            case .byte, .closed, .failed:
                closePending(request)
            case .unavailable:
                if isShuttingDown {
                    closePending(request)
                } else {
                    retained.append(request)
                }
            }
        }

        // A readiness callback may call pump() again and add peers. Keep those
        // peers instead of overwriting them with only this call's retained set.
        let addedDuringCallback = pending
        if isShuttingDown {
            for request in retained { closePending(request) }
            for request in addedDuringCallback { closePending(request) }
            pending.removeAll()
        } else {
            pending = addedDuringCallback + retained
        }
    }
}
