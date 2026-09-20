// fanglass-helper — privileged daemon that performs SMC fan writes on behalf of the app.
// Listens on /var/run/fanglass.sock (JSON-lines, one request per connection).
//
// Commands:
//   {"cmd":"ping"}                      → {"ok":true,"version":2}
//   {"cmd":"hold","fan":0,"rpm":2500}   → hold fan at rpm; helper re-asserts every 1s
//   {"cmd":"auto","fan":0}              → return fan to system control
//   {"cmd":"autoAll"}                   → all fans back to system control
//   {"cmd":"status"}                    → {"ok":true,"holds":{"0":2500}}
//
// Safety: macOS re-asserts automatic control, so "hold" mode re-writes the target
// every second. If the app goes silent for 20s the watchdog restores auto, and
// SIGTERM/SIGINT restore auto before exiting.
import Foundation

let socketPath = "/var/run/fanglass.sock"
let watchdogInterval: TimeInterval = 20

struct Request: Decodable {
    let cmd: String
    let fan: Int?
    let rpm: Double?
}

final class Helper {
    let smc: SMC
    var lastActivity = Date()
    var holds: [Int: Double] = [:]   // fan index → target rpm
    let stateLock = NSLock()
    var holdTimer: DispatchSourceTimer?

    init?() {
        guard let smc = SMC.shared else { return nil }
        self.smc = smc
    }

    func touch() {
        stateLock.lock(); lastActivity = Date(); stateLock.unlock()
    }

    func setHold(fan: Int, rpm: Double?) {
        stateLock.lock()
        if let rpm { holds[fan] = rpm } else { holds.removeValue(forKey: fan) }
        let active = !holds.isEmpty
        stateLock.unlock()
        if active { startHoldTimer() } else { stopHoldTimer() }
    }

    func startHoldTimer() {
        if holdTimer != nil { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler { [weak self] in self?.assertHolds() }
        t.resume()
        holdTimer = t
    }

    func stopHoldTimer() {
        holdTimer?.cancel()
        holdTimer = nil
    }

    /// Re-write forced mode + target for every held fan (macOS periodically
    /// re-asserts automatic control, so this must run continuously).
    func assertHolds() {
        stateLock.lock()
        let snapshot = holds
        stateLock.unlock()
        guard !snapshot.isEmpty else { return }
        for (fan, rpm) in snapshot {
            if !smc.setFanForced(index: fan, rpm: rpm) {
                FileHandle.standardOutput.write("[helper] setFanForced failed for fan \(fan)\n".data(using: .utf8)!)
            }
        }
    }

    func restoreAutoAll(reason: String) {
        stateLock.lock()
        let fans = Array(holds.keys)
        holds.removeAll()
        stateLock.unlock()
        stopHoldTimer()
        let n = smc.fanCount()
        let targets = fans.isEmpty ? Array(0..<n) : fans
        for i in targets { _ = smc.setFanAuto(index: i) }
        FileHandle.standardOutput.write("[helper] restored auto (\(reason))\n".data(using: .utf8)!)
    }

    func handle(_ req: Request) -> [String: Any] {
        touch()
        switch req.cmd {
        case "ping":
            return ["ok": true, "version": 2]
        case "hold":
            guard let fan = req.fan, let rpm = req.rpm else { return ["ok": false, "error": "missing fan/rpm"] }
            setHold(fan: fan, rpm: rpm)
            // Apply now; the 1s timer only re-asserts against macOS stealing control.
            return ["ok": smc.setFanForced(index: fan, rpm: rpm)]
        case "auto":
            guard let fan = req.fan else { return ["ok": false, "error": "missing fan"] }
            setHold(fan: fan, rpm: nil)
            return ["ok": smc.setFanAuto(index: fan)]
        case "autoAll":
            restoreAutoAll(reason: "client request")
            return ["ok": true]
        case "status":
            stateLock.lock()
            let snapshot = holds
            stateLock.unlock()
            var holdsDict: [String: Double] = [:]
            for (k, v) in snapshot { holdsDict[String(k)] = v }
            return ["ok": true, "holds": holdsDict]
        default:
            return ["ok": false, "error": "unknown cmd"]
        }
    }

    func watchdogCheck() {
        stateLock.lock()
        let silent = Date().timeIntervalSince(lastActivity) > watchdogInterval
        let active = !holds.isEmpty
        stateLock.unlock()
        if silent && active { restoreAutoAll(reason: "watchdog timeout") }
    }
}

guard let helper = Helper() else {
    FileHandle.standardError.write("[helper] cannot open AppleSMC\n".data(using: .utf8)!)
    exit(1)
}

// MARK: socket server

unlink(socketPath)
let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
guard serverFD >= 0 else {
    FileHandle.standardError.write("[helper] socket() failed\n".data(using: .utf8)!)
    exit(1)
}

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
_ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
    socketPath.withCString { cstr in
        strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
    }
}
let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
let bindResult = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        bind(serverFD, sa, addrLen)
    }
}
guard bindResult == 0, listen(serverFD, 8) == 0 else {
    FileHandle.standardError.write("[helper] bind/listen failed: \(String(cString: strerror(errno)))\n".data(using: .utf8)!)
    exit(1)
}
chmod(socketPath, 0o666)
// A dead client during write must not SIGPIPE-kill us (KeepAlive would
// restart, but we'd skip the restore-auto atexit path).
signal(SIGPIPE, SIG_IGN)
FileHandle.standardOutput.write("[helper] listening on \(socketPath)\n".data(using: .utf8)!)

// MARK: watchdog timer + signal handlers (main runloop)

let watchdog = DispatchSource.makeTimerSource(queue: .main)
watchdog.schedule(deadline: .now() + 5, repeating: 5)
watchdog.setEventHandler { helper.watchdogCheck() }
watchdog.resume()

for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        helper.restoreAutoAll(reason: "signal \(sig)")
        unlink(socketPath)
        exit(0)
    }
    src.resume()
}

// MARK: accept loop (background thread)

DispatchQueue.global().async {
    while true {
        var clientAddr = sockaddr_un()
        var len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                accept(serverFD, sa, &len)
            }
        }
        if clientFD < 0 { continue }

        var nosig: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))

        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(clientFD, &chunk, chunk.count)
            if n <= 0 { break }
            data.append(contentsOf: chunk[0..<n])
            if data.contains(0x0a) || data.count > 8192 { break }
        }

        var response: [String: Any] = ["ok": false, "error": "bad request"]
        if let line = data.split(separator: 0x0a).first,
           let req = try? JSONDecoder().decode(Request.self, from: Data(line)) {
            // Serialize all state + timer mutations onto the main queue.
            if Thread.isMainThread {
                response = helper.handle(req)
            } else {
                DispatchQueue.main.sync { response = helper.handle(req) }
            }
        }
        if let out = try? JSONSerialization.data(withJSONObject: response) {
            let payload = out + Data([0x0a])
            payload.withUnsafeBytes { ptr in
                _ = write(clientFD, ptr.baseAddress, payload.count)
            }
        }
        close(clientFD)
    }
}

RunLoop.main.run()
