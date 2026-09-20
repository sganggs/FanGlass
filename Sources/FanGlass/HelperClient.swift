// HelperClient.swift — talks to the privileged fanglass-helper daemon over
// /var/run/fanglass.sock (JSON-lines, one request per connection).
import Foundation

final class HelperClient: @unchecked Sendable {
    static let shared = HelperClient()
    private let socketPath = HelperProtocol.socketPath

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

    /// One round-trip handshake: the protocol version the daemon reports, or
    /// nil when nothing answers. Liveness and version come from the same probe
    /// so the two can never disagree.
    func probe() -> Int? {
        guard let reply = send(["cmd": "ping"]), (reply["ok"] as? Bool) == true else { return nil }
        // A pre-versioning helper (FanGlass 1.0) answers without the field.
        return (reply["version"] as? Int) ?? 1
    }

    var isAvailable: Bool { probe() != nil }

    /// Fan indexes the daemon is currently holding, or nil when it does not
    /// answer. Used at startup to adopt holds left behind by a FanGlass that
    /// was killed rather than quit.
    func heldFans() -> [Int]? {
        guard let reply = send(["cmd": "status"]), (reply["ok"] as? Bool) == true else { return nil }
        guard let holds = reply["holds"] as? [String: Any] else { return [] }
        return holds.keys.compactMap(Int.init)
    }

    /// Why a `hold` did not take. "The daemon is gone" and "the SMC refused the
    /// write" need different words on screen, and collapsing both into `false`
    /// is how the fan card ended up blaming the SMC for a missing helper.
    enum HoldOutcome {
        case applied
        case refused      // the helper answered, the SMC said no
        case unreachable  // nothing answered on the socket
    }

    @discardableResult
    func hold(fan: Int, rpm: Double) -> HoldOutcome {
        guard let reply = send(["cmd": "hold", "fan": fan, "rpm": rpm]) else { return .unreachable }
        return (reply["ok"] as? Bool) == true ? .applied : .refused
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
