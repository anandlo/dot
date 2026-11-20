import Darwin
import Foundation

enum ClosedPort {
    static func make() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw failure("socket", errno) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            let error = failure("inet_pton", errno)
            _ = Darwin.close(descriptor)
            throw error
        }
        address.sin_port = 0
        // Port 0 lets the kernel hand out a free port; closing it refuses connects at once because a bound, non-listening socket drops SYNs on macOS and the client waits for its timeout.
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let error = failure("bind", errno)
            _ = Darwin.close(descriptor)
            throw error
        }

        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &resolved) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.getsockname(descriptor, sockaddrPointer, &length)
            }
        }
        guard named == 0 else {
            let error = failure("getsockname", errno)
            _ = Darwin.close(descriptor)
            throw error
        }
        let port = Int(UInt16(bigEndian: resolved.sin_port))
        guard Darwin.close(descriptor) == 0 else { throw failure("close", errno) }
        return port
    }

    private static func failure(_ operation: String, _ code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed (errno \(code)): \(String(cString: strerror(code)))"]
        )
    }
}
