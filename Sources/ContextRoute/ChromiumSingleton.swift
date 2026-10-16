import Darwin
import Foundation

/// Uses Chromium's existing ProcessSingleton channel, including its profile arguments.
/// Protocol: chrome/browser/process_singleton_posix.cc in the Chromium source tree.
enum ChromiumSingleton {
    enum Outcome {
        case delivered(pid_t)
        case unavailable(String)
        case unconfirmed
    }

    static func deliver(
        in directory: URL,
        executableURL: URL,
        arguments: [String],
        expectedPIDs: Set<pid_t>
    ) -> Outcome {
        let fields = ["START", "/", executableURL.path] + arguments
        guard fields.allSatisfy({ !$0.utf8.contains(0) }) else { return .unavailable("invalid-argument") }
        let message = Array(fields.joined(separator: "\0").utf8)
        guard message.count < 32 * 1024 else { return .unavailable("message-too-large") }

        let socketLink = directory.appendingPathComponent("SingletonSocket")
        let cookieLink = directory.appendingPathComponent("SingletonCookie")
        let lockLink = directory.appendingPathComponent("SingletonLock")
        guard let socketTarget = linkTarget(socketLink), socketTarget.hasPrefix("/"),
              let cookie = linkTarget(cookieLink), !cookie.isEmpty,
              let lock = linkTarget(lockLink),
              let pidComponent = lock.split(separator: "-").last,
              let ownerPID = pid_t(pidComponent), expectedPIDs.contains(ownerPID) else {
            return .unavailable("no-running-endpoint")
        }

        let socketURL = URL(fileURLWithPath: socketTarget)
        let remoteCookie = socketURL.deletingLastPathComponent().appendingPathComponent("SingletonCookie")
        var directoryInfo = stat()
        guard socketURL.deletingLastPathComponent().path.withCString({ lstat($0, &directoryInfo) }) == 0,
              directoryInfo.st_uid == geteuid(), directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryInfo.st_mode & 0o077 == 0,
              linkTarget(remoteCookie) == cookie else { return .unavailable("endpoint-changed") }

        let pathBytes = Array(socketTarget.utf8)
        let addressLength = 2 + pathBytes.count
        guard addressLength <= Int(SOCK_MAXADDRLEN), !pathBytes.contains(0) else {
            return .unavailable("socket-path-too-long")
        }
        // macOS accepts up to 253 path bytes, beyond sockaddr_un.sun_path's SDK size.
        var address = [UInt8](repeating: 0, count: Int(SOCK_MAXADDRLEN))
        address[0] = UInt8(addressLength)
        address[1] = UInt8(AF_UNIX)
        address.replaceSubrange(2..<addressLength, with: pathBytes)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unavailable("socket-create-failed") }
        defer { Darwin.close(fd) }
        let flags = fcntl(fd, F_GETFL)
        var enabled: Int32 = 1
        var sendBufferSize: Int32 = 64 * 1024
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBufferSize, socklen_t(MemoryLayout.size(ofValue: sendBufferSize))) == 0 else {
            return .unavailable("socket-setup-failed")
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + 1_500_000_000
        let connected = address.withUnsafeBytes { bytes in
            Darwin.connect(fd, bytes.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(addressLength))
        }
        if connected != 0 {
            guard errno == EINPROGRESS, wait(fd, for: Int16(POLLOUT), until: deadline) else {
                return .unavailable("connect-failed")
            }
            var connectionError: Int32 = 0
            var errorSize = socklen_t(MemoryLayout.size(ofValue: connectionError))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &connectionError, &errorSize) == 0,
                  connectionError == 0 else { return .unavailable("connect-failed") }
        }

        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        var peerPID: pid_t = 0
        var pidSize = socklen_t(MemoryLayout.size(ofValue: peerPID))
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == geteuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &pidSize) == 0,
              peerPID == ownerPID,
              linkTarget(cookieLink) == cookie, linkTarget(remoteCookie) == cookie,
              linkTarget(lockLink) == lock, linkTarget(socketLink) == socketTarget else {
            return .unavailable("peer-mismatch")
        }

        var written = 0
        while written < message.count {
            guard wait(fd, for: Int16(POLLOUT), until: deadline) else {
                return written == 0 ? .unavailable("write-timeout") : .unconfirmed
            }
            let count = message.withUnsafeBytes { bytes in
                Darwin.send(fd, bytes.baseAddress!.advanced(by: written), message.count - written, 0)
            }
            if count > 0 { written += count }
            else if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            else { return written == 0 ? .unavailable("write-failed") : .unconfirmed }
        }
        _ = Darwin.shutdown(fd, SHUT_WR)

        // Once sent, an absent ACK is ambiguous. Never replay it through another
        // process: the original request might still open a tab after the timeout.
        let acknowledgement = Array("ACK".utf8)
        let shutdown = Array("SHUTDOWN".utf8)
        var response: [UInt8] = []
        while response.count < shutdown.count {
            guard wait(fd, for: Int16(POLLIN), until: deadline) else { return .unconfirmed }
            var buffer = [UInt8](repeating: 0, count: shutdown.count - response.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!, $0.count, 0) }
            if count > 0 {
                response.append(contentsOf: buffer.prefix(count))
                if response == acknowledgement { return .delivered(peerPID) }
                if response == shutdown { return .unavailable("browser-shutting-down") }
                guard acknowledgement.starts(with: response) || shutdown.starts(with: response) else { return .unconfirmed }
            } else if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            else { return .unconfirmed }
        }
        return .unconfirmed
    }

    private static func linkTarget(_ url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    private static func wait(_ fd: Int32, for events: Int16, until deadline: UInt64) -> Bool {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            let timeout = Int32(min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max)))
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let ready = Darwin.poll(&descriptor, 1, timeout)
            if ready > 0 {
                return descriptor.revents & (events | Int16(POLLHUP) | Int16(POLLERR)) != 0
            }
            if ready < 0 && errno == EINTR { continue }
            return false
        }
    }
}
