// fanglass-helper — privileged daemon that performs SMC fan writes on behalf of the app.
// Listens on /var/run/fanglass.sock (JSON-lines, one request per connection).
//
// Commands:
//   {"cmd":"ping"}                      → {"ok":true,"version":6}
//   {"cmd":"hold","fan":0,"rpm":2500}   → hold fan at rpm; helper re-asserts every 1s
//   {"cmd":"auto","fan":0}              → return fan to system control
//   {"cmd":"autoAll"}                   → all fans back to system control
//   {"cmd":"status"}                    → {"ok":true,"holds":{"0":2500}}
//
// Safety: macOS re-asserts automatic control, so "hold" mode re-writes the target
// every second. If the app goes silent for 20s the watchdog restores auto —
// "silent" counts only hold/auto/autoAll, never the ping/status queries, so a
// client that merely polls liveness cannot keep a forgotten hold alive,
// SIGTERM/SIGINT restore auto before exiting, and 10 s of failing SMC writes
// also restores auto instead of hammering hardware that is not listening.
//
// Trust: the socket is reachable by any local process, so the gate is the
// peer's uid (LOCAL_PEERCRED) — only root and the user currently at the console
// may send commands.
import Foundation

let socketPath = HelperProtocol.socketPath
let watchdogInterval: TimeInterval = 20

func log(_ message: String) {
    FileHandle.standardOutput.write("[helper] \(message)\n".data(using: .utf8)!)
}

/// Seconds of *awake* time since boot. Unlike `Date()` this does not advance
/// while the Mac sleeps, which is what "the app has gone quiet" has to mean.
func uptimeSeconds() -> TimeInterval {
    TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
}

/// One log line per 10 s for events a rogue client can trigger in a loop. The
/// log is a root-owned file on the boot volume; it must not be a spam target.
final class LogThrottle {
    private let lock = NSLock()
    private var lastLogged: TimeInterval = -.greatestFiniteMagnitude
    private var suppressed = 0

    func log(_ message: @autoclosure () -> String) {
        lock.lock()
        let now = uptimeSeconds()
        guard now - lastLogged >= 10 else { suppressed += 1; lock.unlock(); return }
        lastLogged = now
        let skipped = suppressed
        suppressed = 0
        lock.unlock()
        FileHandle.standardOutput.write(
            "[helper] \(message())\(skipped > 0 ? " (+\(skipped) suppressed)" : "")\n".data(using: .utf8)!)
    }
}

let rejectionLog = LogThrottle()

/// The uid of whoever is sitting at this Mac, or nil when nobody is.
func consoleUserID() -> uid_t? {
    var info = stat()
    guard stat("/dev/console", &info) == 0 else { return nil }
    return info.st_uid
}

/// Only root and the console user may drive the fans. Without this any local
/// process — including another logged-in user — could pin the fans at minimum.
func peerAuthorized(_ fd: Int32) -> Bool {
    var cred = xucred()
    var len = socklen_t(MemoryLayout<xucred>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &len) == 0,
          cred.cr_version == UInt32(XUCRED_VERSION) else { return false }
    return cred.cr_uid == 0 || cred.cr_uid == consoleUserID()
}

struct Request: Decodable {
    let cmd: String
    let fan: Int?
    let rpm: Double?
}

/// Reachable from every connection thread. The discipline that makes this safe:
/// `holds` and `lastActivity`/`lastActivityUptime` are only ever touched under
/// `stateLock`, and `holdTimer` + `writeFailureStreak` only ever from the main
/// queue (`handle` is called through `DispatchQueue.main.sync`, and the hold and
/// watchdog timers are targeted at `.main`).
final class Helper: @unchecked Sendable {
    let smc: SMC
    var lastActivity = Date()
    /// Awake-time twin of `lastActivity`; see `watchdogCheck`.
    var lastActivityUptime = uptimeSeconds()
    var holds: [Int: Double] = [:]   // fan index → target rpm
    let stateLock = NSLock()
    var holdTimer: DispatchSourceTimer?
    /// Consecutive 1 s cycles in which an SMC write failed (main queue only).
    var writeFailureStreak = 0

    init?() {
        guard let smc = SMC.shared else { return nil }
        self.smc = smc
    }

    func touch() {
        stateLock.lock()
        lastActivity = Date()
        lastActivityUptime = uptimeSeconds()
        stateLock.unlock()
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
        var failed = false
        for (fan, rpm) in snapshot {
            if !smc.setFanForced(index: fan, rpm: rpm) {
                failed = true
                log("setFanForced failed for fan \(fan)")
            }
        }
        // Writes that keep failing mean a stale SMC handle or a model that does
        // not accept forced speeds. Retry the handle, then hand the fans back to
        // macOS rather than re-asserting a target that never lands.
        if failed {
            writeFailureStreak += 1
            if writeFailureStreak == 5 { smc.reopen() }
            if writeFailureStreak >= 10 { restoreAutoAll(reason: "SMC writes failing") }
        } else {
            writeFailureStreak = 0
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
        writeFailureStreak = 0
        for i in targets { _ = smc.setFanAuto(index: i) }
        log("restored auto (\(reason))")
    }

    func handle(_ req: Request) -> [String: Any] {
        // Deliberately NOT a blanket touch(): the watchdog has to mean "nobody is
        // driving the fans any more", and `ping`/`status` are pure queries that a
        // client sends while it is driving nothing. A client that polls liveness
        // every few seconds would otherwise keep a hold it does not even know
        // about alive forever. Only the three commands that change fan state
        // refresh the deadline.
        switch req.cmd {
        case "ping":
            return ["ok": true, "version": HelperProtocol.version]
        case "hold":
            guard let fan = req.fan, let rpm = req.rpm else { return ["ok": false, "error": "missing fan/rpm"] }
            // An index no fan answers to would be re-asserted (and logged)
            // once a second until the failure streak gives up 10 s later.
            guard fan >= 0, fan < smc.fanCount(), rpm.isFinite else {
                return ["ok": false, "error": "bad fan/rpm"]
            }
            touch()
            setHold(fan: fan, rpm: rpm)
            // Apply now; the 1s timer only re-asserts against macOS stealing control.
            return ["ok": smc.setFanForced(index: fan, rpm: rpm)]
        case "auto":
            guard let fan = req.fan else { return ["ok": false, "error": "missing fan"] }
            touch()
            setHold(fan: fan, rpm: nil)
            return ["ok": smc.setFanAuto(index: fan)]
        case "autoAll":
            touch()
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
        // Both clocks must agree the app is gone. The wall clock alone jumps by
        // the whole sleep duration the instant the Mac wakes, which fired the
        // watchdog on every wake and dropped a hold the app was about to renew;
        // the uptime clock alone would be fooled by nothing, but it stops during
        // sleep, so requiring both means "silent while we were awake".
        let silent = Date().timeIntervalSince(lastActivity) > watchdogInterval
            && uptimeSeconds() - lastActivityUptime > watchdogInterval
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
// Reachable by the console user; who may actually issue commands is decided by
// peerAuthorized() on every connection, not by the file mode.
chmod(socketPath, 0o666)
// A dead client during write must not SIGPIPE-kill us (KeepAlive would
// restart, but we'd skip the restore-auto atexit path).
signal(SIGPIPE, SIG_IGN)
log("listening on \(socketPath)")

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

// MARK: connection handling

/// Read one JSON line, answer it, close. Runs on a concurrent queue: a client
/// that connects and never speaks must not stop the next one being served.
func serve(_ clientFD: Int32) {
    defer { close(clientFD) }

    var nosig: Int32 = 1
    setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
    // Without this a client that sends nothing parks a thread forever. The app
    // never takes more than a few ms to write its one line.
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var data = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(clientFD, &chunk, chunk.count)
        // n < 0 is the receive timeout (EAGAIN) as well as a hard error; both
        // mean "no complete line is coming".
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
}

// MARK: accept loop (background thread)

let connectionQueue = DispatchQueue(label: "fanglass.helper.connections", attributes: .concurrent)

DispatchQueue.global().async {
    while true {
        var clientAddr = sockaddr_un()
        var len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                accept(serverFD, sa, &len)
            }
        }
        if clientFD < 0 {
            // EINTR/ECONNABORTED are transient; anything else would spin, so
            // yield the thread rather than burn a core on a broken listener.
            if errno != EINTR && errno != ECONNABORTED { usleep(100_000) }
            continue
        }
        guard peerAuthorized(clientFD) else {
            rejectionLog.log("rejected connection from an unauthorized uid")
            close(clientFD)
            continue
        }
        // Accept stays hot; only the (blocking) conversation moves off it.
        connectionQueue.async { serve(clientFD) }
    }
}

RunLoop.main.run()
