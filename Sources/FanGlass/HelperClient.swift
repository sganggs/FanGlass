// HelperClient.swift — talks to the privileged fanglass-helper daemon over
// /var/run/fanglass.sock (JSON-lines, one request per connection).
import Foundation

final class HelperClient: @unchecked Sendable {
    static let shared = HelperClient()
    private let socketPath = "/var/run/fanglass.sock"

    /// Send one command, return the response dictionary. nil on any failure.
    @discardableResult
    func send(_ command: [String: Any]) -> [String: Any]? {
        guard JSONSerialization.isValidJSONObject(command),
              let payload = try? JSONSerialization.data(withJSONObject: command) else { return nil }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var nosig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        let message = payload + Data([0x0a])
        let sent = message.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress, message.count)
        }
        guard sent > 0 else { return nil }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            response.append(contentsOf: chunk[0..<n])
            if response.contains(0x0a) { break }
        }
        guard !response.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: response) as? [String: Any]
    }

    var isAvailable: Bool {
        (send(["cmd": "ping"])?["ok"] as? Bool) == true
    }

    @discardableResult
    func hold(fan: Int, rpm: Double) -> Bool {
        (send(["cmd": "hold", "fan": fan, "rpm": rpm])?["ok"] as? Bool) == true
    }

    @discardableResult
    func auto(fan: Int) -> Bool {
        (send(["cmd": "auto", "fan": fan])?["ok"] as? Bool) == true
    }

    @discardableResult
    func autoAll() -> Bool {
        (send(["cmd": "autoAll"])?["ok"] as? Bool) == true
    }
}
