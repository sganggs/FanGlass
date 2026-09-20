// HelperInstaller.swift — runs the bundled install/uninstall scripts (each shows
// one administrator authorization dialog) and reports a phase the UI can render.
//
// Success is *verified*, never assumed: `launchctl bootstrap` returning 0 only
// means the job was accepted, so after a clean exit we poll the socket until the
// daemon actually answers.
import Foundation

@MainActor
final class HelperInstaller {
    enum Phase: Equatable {
        case idle
        case authorizing
        case verifying
        case installed
        case uninstalled
        case canceled
        case failed(String)
    }

    /// Where the request came from — only used to pick the prompt's wording.
    enum Reason: Equatable {
        case firstLaunch
        case modePicked
        case presetPicked
        case banner
        case statusPill
        case outdated
        case manual
    }

    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { onPhaseChange?(phase) } }
    }

    /// AppState mirrors the phase into an @Published property; nesting an
    /// ObservableObject inside another one would not refresh any view.
    var onPhaseChange: ((Phase) -> Void)?

    var isBusy: Bool { phase.isBusy }

    // MARK: - actions

    /// Installs the helper, then waits for it to answer. Completion carries the
    /// protocol version the freshly installed daemon reports, or nil on failure.
    func install(completion: @escaping (Int?) -> Void) {
        guard !isBusy else { return }
        phase = .authorizing
        Task { [self] in
            let result = await Self.runScript("install.sh")
            if result.canceled {
                phase = .canceled
                completion(nil)
                return
            }
            guard result.ok else {
                phase = .failed(result.message)
                completion(nil)
                return
            }
            phase = .verifying
            if let version = await Self.waitForHelper() {
                phase = .installed
                completion(version)
            } else {
                phase = .failed("助手已安装但未能连接,请重试")
                completion(nil)
            }
        }
    }

    func uninstall(completion: @escaping (Bool) -> Void) {
        guard !isBusy else { return }
        phase = .authorizing
        Task { [self] in
            let result = await Self.runScript("uninstall.sh")
            if result.canceled {
                phase = .canceled
                completion(false)
            } else if result.ok {
                phase = .uninstalled
                completion(true)
            } else {
                phase = .failed(result.message)
                completion(false)
            }
        }
    }

    /// Clears a finished phase so the Settings card stops showing a stale note.
    func clearNote() {
        if !isBusy { phase = .idle }
    }

    // MARK: - script execution (off the main actor)

    private struct ScriptResult: Sendable {
        let ok: Bool
        let canceled: Bool
        let message: String
    }

    private static func runScript(_ name: String) async -> ScriptResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<ScriptResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runScriptSync(name))
            }
        }
    }

    /// Blocking: runs on a background queue, never on the main actor.
    private nonisolated static func runScriptSync(_ name: String) -> ScriptResult {
        guard let script = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "scripts") else {
            return ScriptResult(ok: false, canceled: false, message: "找不到 \(name)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        // The scripts prefer these over their own path guesses, so the app can
        // install from inside the bundle wherever the bundle happens to live.
        if let helper = Bundle.main.url(forResource: "fanglass-helper", withExtension: nil) {
            env["FANGLASS_HELPER"] = helper.path
        }
        if let plist = Bundle.main.url(forResource: "com.fanglass.helper", withExtension: "plist") {
            env["FANGLASS_PLIST"] = plist.path
        }
        // install.sh verifies the daemon by pinging it; this is the version the
        // reply has to carry. Inside the bundle it cannot read HelperProtocol.swift.
        env["FANGLASS_HELPER_VERSION"] = String(HelperProtocol.version)
        process.environment = env

        let errPipe = Pipe()
        process.standardError = errPipe
        // Only stderr carries anything we report; discarding stdout means one
        // fewer pipe that could fill up and deadlock the child.
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ScriptResult(ok: false, canceled: false, message: error.localizedDescription)
        }
        // Drain before waiting: a full pipe buffer would block the child forever.
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let errText = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ok = process.terminationStatus == 0
        // osascript reports a declined authorization as error -128, and that code
        // is not localized. Match only on it: the scripts print their own failure
        // line too, and substring-matching the word would mask real errors.
        let canceled = !ok && errText.contains("-128")
        let message = errText.isEmpty
            ? "操作失败(退出码 \(process.terminationStatus))"
            : errText
        return ScriptResult(ok: ok, canceled: canceled, message: message)
    }

    /// Poll the socket for up to ~6 s. install.sh already waits for the socket
    /// node to appear; this confirms the daemon actually talks.
    private static func waitForHelper() async -> Int? {
        for attempt in 0..<24 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 250_000_000) }
            let version = await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: HelperClient.shared.probe())
                }
            }
            if let version { return version }
        }
        return nil
    }
}

// MARK: - presentation

extension HelperInstaller.Phase {
    var isBusy: Bool { self == .authorizing || self == .verifying }

    /// Something the user should act on, rather than a neutral progress note.
    var isProblem: Bool {
        switch self {
        case .canceled, .failed: return true
        default: return false
        }
    }

    /// One line of status, shared by the Settings card and the prompt sheet.
    var note: String? {
        switch self {
        case .idle:          return nil
        case .authorizing:   return "正在请求管理员授权…"
        case .verifying:     return "正在启动助手…"
        case .installed:     return "助手已安装并连接"
        case .uninstalled:   return "助手已卸载"
        case .canceled:      return "已取消授权,风扇仍由系统自动控制"
        case .failed(let m): return m
        }
    }
}

extension HelperInstaller.Reason {
    var title: String {
        switch self {
        case .firstLaunch: return "FanGlass 需要一次管理员授权"
        case .outdated:    return "特权助手需要更新"
        case .manual:      return "安装特权助手"
        // Neither entry point came from picking a mode: one is a warning
        // banner, the other the top-bar status pill.
        case .banner, .statusPill:
            return "安装特权助手以控制风扇转速"
        case .modePicked, .presetPicked:
            return "要让这个模式生效,需要先安装特权助手"
        }
    }

    /// The caveat, in one line. Shown by both the sheet and the NSAlert: the
    /// alert is the only thing a first-launch user sees before typing an admin
    /// password, so it must not be the vaguer of the two.
    static let uninstallNote =
        "升级或卸载助手时会再询问一次；助手常驻后台，可随时在「设置 → 特权助手」中卸载。"

    var message: String {
        switch self {
        case .outdated:
            return "已安装的助手版本较旧,可能无法执行这一版 FanGlass 的指令。更新只需再授权一次。"
        default:
            // Deliberately not "之后无需再输入密码"：升级或卸载助手时还会问一次，
            // and a promise the app's own code path breaks is worse than none.
            // `uninstallNote` carries that caveat; this line stays one sentence.
            return "写入风扇转速需要 root 权限，因此需要一次管理员授权，安装负责写入的后台助手。"
        }
    }

    var confirmTitle: String { self == .outdated ? "更新助手" : "安装助手" }
}
