import Darwin
import Foundation

enum ProbeOutcome: Sendable, Equatable {
    case success
    case failure(String)
}

/// Blocking socket helpers. Call these off the main actor.
enum Net {

    // MARK: - Plain TCP

    static func checkTCP(host: String, port: Int, timeout: TimeInterval) -> ProbeOutcome {
        switch open(host: host, port: port, timeout: timeout) {
        case .failure(let why): return .failure(why)
        case .success(let fd):
            close(fd)
            return .success
        }
    }

    // MARK: - SOCKS5

    /// Ask the proxy to CONNECT to host:port. The hostname is sent as a domain
    /// name (ATYP 0x03) so the *proxy* resolves it — internal names that do not
    /// resolve locally still work, and a failure here is a real routing answer.
    static func socks5Probe(proxyHost: String, proxyPort: Int,
                            host: String, port: Int,
                            timeout: TimeInterval) -> ProbeOutcome {
        let fd: Int32
        switch open(host: proxyHost, port: proxyPort, timeout: timeout) {
        case .failure(let why): return .failure("proxy unreachable: \(why)")
        case .success(let f): fd = f
        }
        defer { close(fd) }

        setTimeouts(fd, timeout)

        // Greeting: version 5, one method, "no authentication".
        guard send(fd, [0x05, 0x01, 0x00]) else {
            return .failure("could not talk to the proxy")
        }
        guard let greeting = recv(fd, 2), greeting.count == 2 else {
            return .failure("proxy closed the connection during handshake")
        }
        guard greeting[0] == 0x05 else { return .failure("not a SOCKS5 proxy") }
        guard greeting[1] == 0x00 else {
            return .failure("proxy wants authentication, which is not supported here")
        }

        let name = Array(host.utf8)
        guard name.count <= 255 else { return .failure("hostname too long") }
        var request: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(name.count)]
        request.append(contentsOf: name)
        request.append(UInt8((port >> 8) & 0xff))
        request.append(UInt8(port & 0xff))

        guard send(fd, request) else { return .failure("could not send the connect request") }
        guard let reply = recv(fd, 4), reply.count >= 2 else {
            // This is the signature of a tunnel that is up while the far side
            // cannot route to the target.
            return .failure("proxy closed the connection without replying")
        }
        guard reply[0] == 0x05 else { return .failure("malformed proxy reply") }

        switch reply[1] {
        case 0x00: return .success
        case 0x01: return .failure("general SOCKS server failure")
        case 0x02: return .failure("connection not allowed by ruleset")
        case 0x03: return .failure("network unreachable from the proxy")
        case 0x04: return .failure("host unreachable from the proxy")
        case 0x05: return .failure("connection refused by the host")
        case 0x06: return .failure("TTL expired")
        case 0x07: return .failure("command not supported")
        case 0x08: return .failure("address type not supported")
        default:   return .failure("SOCKS error \(reply[1])")
        }
    }

    // MARK: - Primitives

    private enum OpenResult {
        case success(Int32)
        case failure(String)
    }

    private static func open(host: String, port: Int, timeout: TimeInterval) -> OpenResult {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &list)
        guard rc == 0, let head = list else {
            return .failure("cannot resolve \(host)")
        }
        defer { freeaddrinfo(head) }

        var lastError = "connection failed"
        var candidate: UnsafeMutablePointer<addrinfo>? = head
        while let info = candidate {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd < 0 { candidate = info.pointee.ai_next; continue }

            // Non-blocking connect so the timeout is ours, not the kernel's.
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

            let cr = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
            if cr == 0 {
                _ = fcntl(fd, F_SETFL, flags)
                return .success(fd)
            }
            if errno != EINPROGRESS {
                lastError = String(cString: strerror(errno))
                close(fd)
                candidate = info.pointee.ai_next
                continue
            }

            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(timeout * 1000))
            if ready <= 0 {
                lastError = ready == 0 ? "timed out" : String(cString: strerror(errno))
                close(fd)
                candidate = info.pointee.ai_next
                continue
            }

            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
            if soErr != 0 {
                lastError = String(cString: strerror(soErr))
                close(fd)
                candidate = info.pointee.ai_next
                continue
            }

            _ = fcntl(fd, F_SETFL, flags)
            return .success(fd)
        }
        return .failure(lastError)
    }

    private static func setTimeouts(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func send(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                Darwin.send(fd, raw.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
            }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    private static func recv(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                Darwin.recv(fd, raw.baseAddress!.advanced(by: got), count - got, 0)
            }
            if n <= 0 { return got > 0 ? Array(buffer[0..<got]) : nil }
            got += n
        }
        return buffer
    }
}
