// AppState.swift — runtime engine: sensor scanning/polling, fan control loop, alerts.
//
// Isolation model:
//  • @Published UI state lives on MainActor.
//  • A serial worker queue does all SMC reads (fast, but numerous) and all
//    blocking helper-socket I/O. Worker only touches `nonisolated` snapshots.
//  • Control decisions are made on MainActor; the resulting helper commands
//    are dispatched to the worker (fire-and-forget, one connection each).
import Foundation
import SwiftUI
import UserNotifications
import ServiceManagement

struct SensorSample: Equatable {
    let time: Date
    let value: Double
}

struct SensorGroupState: Identifiable {
    /// Stable classification id ("cpu", "gpu", …). Everything that compares,
    /// sorts or persists a group uses this; `name` is display-only.
    let id: String
    var keys: [String]
    var value: Double = 0
    var history: [SensorSample] = []

    var name: String { AppState.groupName(id) }
}

@MainActor
final class AppState: ObservableObject {
    static let historyLimit = 240

    @Published private(set) var groups: [SensorGroupState] = []
    @Published private(set) var fans: [FanStatus] = []
    @Published private(set) var fanHistories: [Int: [SensorSample]] = [:]
    @Published private(set) var scanning = true
    /// False when this Mac exposes no writable fan target (fanless models, or
    /// an SMC that reports fans read-only). Sensors still work; the control UI
    /// says so rather than saving modes that can never take effect.
    @Published private(set) var fanControlSupported = true
    /// Set when a whole poll came back without a single usable reading. A stale
    /// SMC handle must never be mistaken for a cold machine.
    @Published private(set) var sensorsUnavailable = false
    /// Set when the helper reports that a fan write did not land.
    @Published private(set) var controlWriteFailed = false
    @Published private(set) var helperAvailable = false
    /// Protocol version the installed daemon reports; nil when none answers.
    @Published private(set) var helperVersion: Int?
    @Published private(set) var targetRPMs: [Int: Double] = [:]
    /// Mirrors `installer.phase` — a nested ObservableObject would never
    /// refresh a view, so the installer pushes its phase here instead.
    @Published private(set) var installPhase: HelperInstaller.Phase = .idle
    @Published private(set) var installReason: HelperInstaller.Reason = .manual
    /// Drives the onboarding sheet in RootView.
    @Published var showInstallSheet = false
    /// Tab the main window should open on. RootView owns `tab` as private
    /// @State, so this is the only way in from the menu-bar panel.
    @Published var pendingTab: AppTab?
    @Published var settings: AppSettings {
        didSet {
            scheduleSettingsSave()
            AppState.restoreAutoOnQuitFlag = settings.restoreAutoOnQuit
        }
    }

    // Worker-only state (serial queue → data-race safe by construction).
    nonisolated private let worker = DispatchQueue(label: "fanglass.worker", qos: .userInitiated)
    /// Helper socket I/O only. Sharing `worker` meant one unresponsive daemon
    /// froze the sensor stream for its whole 2 s timeout, because the poll timer
    /// is targeted at that same serial queue.
    nonisolated private let helperQueue = DispatchQueue(label: "fanglass.helper", qos: .userInitiated)
    nonisolated private let saveQueue = DispatchQueue(label: "fanglass.settings", qos: .utility)
    nonisolated(unsafe) private var smc: SMC?
    nonisolated(unsafe) private var scanSnapshot: [(id: String, keys: [String])] = []
    nonisolated(unsafe) private var fanCountSnapshot = 0
    nonisolated(unsafe) private var pollTick = 0
    /// Consecutive polls that read nothing at all (worker-only).
    nonisolated(unsafe) private var readFailureStreak = 0
    /// Poll ticks between helper re-pings, recomputed from `pollInterval` so the
    /// period stays ~10 s however fast the sensors are sampled.
    nonisolated(unsafe) private var helperCheckDivisor = 10

    // Control bookkeeping (MainActor only).
    private var lastSentRPM: [Int: Double] = [:]
    private var lastSentTime: [Int: Date] = [:]
    private var fanForcedActive: [Int: Bool] = [:]
    private var lastOverheatAlert = Date.distantPast
    private var pollTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?
    private var pendingSave: DispatchWorkItem?
    /// Set once termination begins so nothing re-forces a fan behind the
    /// restore-to-auto that is on its way out.
    private var shuttingDown = false
    /// App Nap assertion, held only while a fan is actually under our control.
    private var controlActivity: NSObjectProtocol?

    // Privileged-helper install flow.
    let installer = HelperInstaller()
    /// What the user asked for while no helper was installed, replayed once one is.
    private var pendingIntent: (() -> Void)?
    /// True from the moment an NSAlert is scheduled until it is dismissed.
    /// `installer.isBusy` starts only once the install does, which leaves the
    /// whole time the prompt is on screen unguarded.
    private var promptOnScreen = false
    /// `lastPromptedHelperVersion` before the outdated-helper prompt optimistically
    /// bumped it, so a failed update can put it back instead of silently never
    /// asking again about a version that never got installed.
    private var prePromptHelperVersion: Int?
    /// Clears a finished install note after a few seconds (see below).
    private var noteExpiry: Task<Void, Never>?

    /// Read by AppDelegate on termination (must stay nonisolated).
    nonisolated(unsafe) static var restoreAutoOnQuitFlag = true
    /// The live engine. AppDelegate is instantiated by SwiftUI and has no other
    /// way to reach it when the app is asked to quit.
    static weak var shared: AppState?

    init() {
        settings = SettingsStore.load()
        AppState.shared = self
        AppState.restoreAutoOnQuitFlag = settings.restoreAutoOnQuit
        let version = HelperClient.shared.probe()
        helperAvailable = version != nil
        helperVersion = version
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        applyLaunchAtLogin()
        installer.onPhaseChange = { [weak self] phase in
            self?.installPhase = phase
            self?.scheduleNoteExpiry(for: phase)
        }
        observeSystemEvents()
        worker.async { [weak self] in self?.bootstrap() }
    }

    /// The socket can disappear while the Mac sleeps, and waking or switching
    /// back to FanGlass is exactly when the status pill gets looked at.
    private func observeSystemEvents() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshHelperStatus() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshHelperStatus() }
        }
    }

    func restartPolling() {
        startPolling()
    }

    // MARK: - bootstrap / scanning (worker)

    nonisolated private func bootstrap() {
        guard let smc = SMC.shared else {
            Task { @MainActor in self.scanning = false }
            return
        }
        self.smc = smc

        let keys = smc.allKeys()
        // Keep every key that DECODES, not only the ones in range at this
        // instant: power-gated blocks read 0 °C while their domain is asleep and
        // would otherwise be excluded for the whole session. Each sample is
        // range-checked in pollOnce instead.
        var classified: [(id: String, key: String, value: Double?)] = []
        for key in keys where key.hasPrefix("T") {
            guard let raw = smc.readFloat(key), let id = AppState.classify(key: key) else { continue }
            classified.append((id, key, AppState.plausible(raw) ? raw : nil))
        }
        var order: [String] = []
        var byID: [String: SensorGroupState] = [:]
        var evidence: Set<String> = []   // groups that produced a real reading
        for item in classified {
            if byID[item.id] == nil {
                byID[item.id] = SensorGroupState(id: item.id, keys: [])
                order.append(item.id)
            }
            guard var group = byID[item.id] else { continue }
            group.keys.append(item.key)
            if let v = item.value {
                evidence.insert(item.id)
                group.value = max(group.value, v)
            }
            byID[item.id] = group
        }
        var groups = order.compactMap { byID[$0] }.filter { evidence.contains($0.id) }
        let priority = ["cpu": 0, "gpu": 1, "memory": 2, "power": 3, "system": 4, "ambient": 5, "other": 6]
        groups.sort { (priority[$0.id] ?? 9) < (priority[$1.id] ?? 9) }

        let fanCount = smc.fanCount()
        let fanStatuses = (0..<fanCount).compactMap { smc.fanStatus($0) }
        let controllable = smc.fanControlSupported()
        scanSnapshot = groups.map { ($0.id, $0.keys) }
        fanCountSnapshot = fanCount

        Task { @MainActor in
            self.groups = groups
            self.fans = fanStatuses
            self.fanControlSupported = controllable
            self.scanning = false
            self.startPolling()
            self.startHeartbeat()
            self.reconcileHelperHolds()
            self.promptForHelperIfNeeded()
        }
    }

    /// The daemon outlives the app. If FanGlass was killed rather than quit
    /// (crash, Force Quit, killall) it can still be holding fans this process
    /// knows nothing about, and `releaseToAuto` only ever releases what *this*
    /// process forced — so an inherited hold would be re-asserted once a second
    /// with nothing able to call it off. Claim those holds on the way up:
    /// whatever `controlDecide` will drive becomes ours to release, and anything
    /// it will never visit (unsupported hardware, a fan index that is not in
    /// `fans`) is handed straight back to macOS.
    private func reconcileHelperHolds() {
        helperQueue.async { [weak self] in
            guard let held = HelperClient.shared.heldFans(), !held.isEmpty else { return }
            Task { @MainActor in self?.adoptHelperHolds(held) }
        }
    }

    private func adoptHelperHolds(_ held: [Int]) {
        let managed = Set(fans.map(\.index))
        for fan in held {
            if fanControlSupported, managed.contains(fan) {
                fanForcedActive[fan] = true
            } else {
                helperQueue.async { HelperClient.shared.auto(fan: fan) }
            }
        }
        controlDecide()
    }

    /// A sensor reading worth trusting. The upper bound is generous enough for
    /// Intel package sensors near TjMax; the lower one drops power-gated blocks
    /// that report 0 °C while their domain is asleep.
    nonisolated static func plausible(_ value: Double) -> Bool { value > 5 && value < 150 }

    /// SMC key prefix → sensor group id. Apple moves the core sensors to a new
    /// key family every few chip generations, so the table names the generation
    /// each rule is for; anything unrecognised lands in "other" rather than
    /// being mislabelled as something it is not.
    ///   M1 / M2 / M4 / M5   CPU P-cores Tp*, E-cores Te*, GPU Tg*
    ///   M3                  CPU Tf0*/Tf4*, GPU Tf1*/Tf2*  (no Tp*/Tg* at all)
    ///   Intel               CPU TC0*/TCA*, GPU TG0*
    nonisolated private static func classify(key: String) -> String? {
        if key == "TVA0" { return "ambient" }
        if key.hasPrefix("Tp") { return "cpu" }
        if key.hasPrefix("Te") { return "cpu" }        // efficiency cores (M3/M4)
        if key.hasPrefix("Tf") {
            // M3 splits CPU and GPU by the second nibble. M4's TfC0/TfC1 are
            // neither and stay unclassified.
            switch key.dropFirst(2).first {
            case "0", "4": return "cpu"
            case "1", "2": return "gpu"
            default: return "other"
            }
        }
        if key.hasPrefix("Tg") { return "gpu" }
        if key.hasPrefix("TC0") || key.hasPrefix("TCA") { return "cpu" }   // Intel
        if key.hasPrefix("TG0") { return "gpu" }                           // Intel
        if key.hasPrefix("Tm") { return "memory" }
        if key.hasPrefix("Ts") { return "system" }
        if ["TPD", "TRD", "TPS", "TVS", "TVV", "TVD", "TW0"].contains(where: key.hasPrefix) {
            return "power"
        }
        if ["TH0", "TIE", "TSC", "TMV", "TUV", "TT0", "Ta0", "TN0", "TB0", "TA0"].contains(where: key.hasPrefix) {
            return "system"
        }
        // TCM* is a composite/threshold sensor that tracks the hottest core;
        // grouping it under "system" made System read like a second CPU number.
        return "other"
    }

    /// The group's display name. Split from `classify` so the id — which is
    /// persisted in settings.json as the curve's control source — never depends
    /// on the UI language. Resolving the string off the main thread is fine.
    nonisolated static func groupName(_ id: String) -> String {
        switch id {
        case "cpu":     return String(localized: "CPU")
        case "gpu":     return String(localized: "GPU")
        case "memory":  return String(localized: "Memory")
        case "power":   return String(localized: "Power")
        case "system":  return String(localized: "System")
        case "ambient": return String(localized: "Ambient")
        default:        return String(localized: "Other")
        }
    }

    // MARK: - polling

    /// Self-cancelling: moving the sampling-interval slider while the SMC scan is
    /// still running used to leave the bootstrap's timer running with nothing
    /// holding a reference to it, polling forever at double rate.
    private func startPolling() {
        guard !shuttingDown else { return }
        pollTimer?.cancel()
        pollTimer = nil
        helperCheckDivisor = max(1, Int((10.0 / max(0.1, settings.pollInterval)).rounded()))
        let t = DispatchSource.makeTimerSource(queue: worker)
        t.schedule(deadline: .now(), repeating: settings.pollInterval)
        t.setEventHandler { [weak self] in self?.pollOnce() }
        t.resume()
        pollTimer = t
    }

    /// Re-assert held fans on a fixed cadence. The helper hands every fan back
    /// to macOS after 20 s of silence, and riding the poll timer for that made
    /// the margin a function of the sampling-interval slider — at 3 s the period
    /// was already ~6 s, and anything that delayed a tick ate into the rest.
    private func startHeartbeat() {
        heartbeatTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in
            Task { @MainActor in self?.controlDecide() }
        }
        t.resume()
        heartbeatTimer = t
    }

    // MARK: - App Nap

    /// FanGlass normally runs with no open window, which is exactly what App Nap
    /// looks for, and a throttled heartbeat trips the helper's watchdog. The
    /// assertion is held only while a fan is ours, and deliberately uses the
    /// ...AllowingIdleSystemSleep variant: defeating App Nap must not also stop
    /// the Mac from sleeping.
    private func beginControlActivity() {
        guard controlActivity == nil else { return }
        controlActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "FanGlass fan control"
        )
    }

    private func endControlActivity() {
        guard let controlActivity else { return }
        ProcessInfo.processInfo.endActivity(controlActivity)
        self.controlActivity = nil
    }

    nonisolated private func pollOnce() {
        guard let smc else { return }
        var newValues: [String: Double] = [:]
        for (id, keys) in scanSnapshot {
            var best: Double?
            for key in keys {
                guard let v = smc.readFloat(key), AppState.plausible(v) else { continue }
                best = max(best ?? v, v)
            }
            // Only publish what was actually read. A group left out here keeps
            // its last value instead of reporting a fabricated 0 °C.
            if let best { newValues[id] = best }
        }
        let fanStatuses = (0..<fanCountSnapshot).compactMap { smc.fanStatus($0) }

        // A stale io_connect_t (sleep/wake, service re-match) fails every read.
        // Taken as 0 °C that would drive a curve to minimum RPM and keep
        // re-asserting it — with the 5 s heartbeat holding off the helper's
        // watchdog — while the machine heats up. Treat it as "no data" instead,
        // and retry the handle.
        let blackout = newValues.isEmpty && !scanSnapshot.isEmpty
        if blackout {
            readFailureStreak &+= 1
            if readFailureStreak % 5 == 0 { smc.reopen() }
        } else {
            readFailureStreak = 0
        }

        Task { @MainActor in
            self.applyPollResults(sensorValues: newValues, fanStatuses: fanStatuses, sensorsOK: !blackout)
        }

        // Re-ping the helper about every 10 s: it can be installed, uninstalled,
        // updated or watchdog-stopped while the app runs, and a stale flag makes
        // the status pill and the mode highlight assert things the daemon is not
        // doing. Runs after the UI hop so a dead socket's timeout never delays
        // sensors, and only assigns on change so views are not invalidated every tick.
        pollTick &+= 1
        if pollTick % helperCheckDivisor == 0 {
            helperQueue.async {
                let version = HelperClient.shared.probe()
                Task { @MainActor in self.applyHelperProbe(version) }
            }
        }
    }

    private func applyPollResults(sensorValues: [String: Double], fanStatuses: [FanStatus], sensorsOK: Bool) {
        let now = Date()
        for i in groups.indices {
            if let v = sensorValues[groups[i].id] {
                groups[i].value = v
                groups[i].history.append(SensorSample(time: now, value: v))
                if groups[i].history.count > AppState.historyLimit {
                    groups[i].history.removeFirst(groups[i].history.count - AppState.historyLimit)
                }
            }
        }
        // Keep the last known fans when a transient failure returns none:
        // clearing them would flash "No fans detected" and stall the control loop.
        if !fanStatuses.isEmpty || fans.isEmpty { fans = fanStatuses }
        let unavailable = !sensorsOK
        if sensorsUnavailable != unavailable { sensorsUnavailable = unavailable }
        for fan in fanStatuses {
            var h = fanHistories[fan.index] ?? []
            h.append(SensorSample(time: now, value: fan.actualRPM))
            if h.count > AppState.historyLimit { h.removeFirst(h.count - AppState.historyLimit) }
            fanHistories[fan.index] = h
        }
        checkOverheat()
        controlDecide()
    }

    // MARK: - control decisions (MainActor; sends dispatched to worker)

    /// The temperature the curve follows, or nil when nothing trustworthy is
    /// available. Callers must not substitute 0 — that is the whole point.
    var controlTemperatureValue: Double? {
        guard !sensorsUnavailable else { return nil }
        if let g = groups.first(where: { $0.id == settings.controlSource }) { return g.value }
        // "max", or a saved source this Mac does not have (different chip
        // family, or a group retired by an update — Settings says which).
        return loadGroups.map(\.value).max()
    }

    /// The groups that stand for how hard this Mac is working. Ambient is the
    /// room, and Other is the catch-all the menu-bar panel hides — a headline or an
    /// overheat alert naming a sensor no visible row explains is worse than none.
    private var loadGroups: [SensorGroupState] {
        groups.filter { $0.id != "ambient" && $0.id != "other" }
    }

    /// True when the saved control source has no matching group on this Mac.
    var controlSourceMissing: Bool {
        let id = settings.controlSource
        return id != "max" && !groups.isEmpty && !groups.contains { $0.id == id }
    }

    private func controlDecide() {
        // Nothing to decide without a helper to carry it out, or on hardware
        // that has no writable fan target — a saved config copied from another
        // Mac must not make the helper hammer the SMC once a second.
        guard !shuttingDown else { return }
        guard helperAvailable, fanControlSupported else { endControlActivity(); return }
        for fan in fans {
            let config = settings.fanConfig(for: fan.index)
            switch config.mode {
            case .auto:
                releaseToAuto(fan: fan.index)

            case .fixed:
                let rpm = fan.minRPM + config.fixedPercent / 100 * (fan.maxRPM - fan.minRPM)
                sendHold(fan: fan.index, rpm: rpm)

            case .curve:
                guard let temp = controlTemperatureValue else {
                    // No trustworthy temperature: hand the fan back to macOS
                    // rather than act on what the curve says about 0 °C.
                    releaseToAuto(fan: fan.index)
                    continue
                }
                let pct = CurveMath.evaluate(
                    xs: config.curve.map(\.temp),
                    ys: config.curve.map(\.percent),
                    x: temp
                )
                // `max(0, min(100, .nan))` is 100 in Swift, so a non-finite
                // result would mean full speed rather than an obvious failure.
                guard pct.isFinite else {
                    releaseToAuto(fan: fan.index)
                    continue
                }
                let rpm = fan.minRPM + max(0, min(100, pct)) / 100 * (fan.maxRPM - fan.minRPM)
                sendHold(fan: fan.index, rpm: rpm)
            }
        }
        updateControlActivity()
    }

    /// Hold the App Nap assertion exactly while at least one fan is forced.
    private func updateControlActivity() {
        if fanForcedActive.values.contains(true) { beginControlActivity() }
        else { endControlActivity() }
    }

    private func sendHold(fan: Int, rpm: Double) {
        let last = lastSentRPM[fan] ?? .greatestFiniteMagnitude
        let lastTime = lastSentTime[fan] ?? .distantPast
        let changed = abs(rpm - last) >= settings.hysteresisRPM
        // Below the 5 s heartbeat timer's period, so every one of its ticks
        // re-asserts rather than every other one.
        let heartbeat = Date().timeIntervalSince(lastTime) > 4
        if changed || heartbeat {
            lastSentRPM[fan] = rpm
            lastSentTime[fan] = Date()
            fanForcedActive[fan] = true
            helperQueue.async { [weak self] in
                let outcome = HelperClient.shared.hold(fan: fan, rpm: rpm)
                Task { @MainActor in self?.applyControlResult(fan: fan, outcome: outcome) }
            }
        }
        targetRPMs[fan] = rpm
    }

    /// Hand a fan back to macOS without touching the user's saved mode.
    private func releaseToAuto(fan: Int) {
        targetRPMs[fan] = 0
        guard fanForcedActive[fan] == true else { return }
        fanForcedActive[fan] = false
        lastSentRPM.removeValue(forKey: fan)
        clearWriteFailureIfIdle()
        helperQueue.async { HelperClient.shared.auto(fan: fan) }
    }

    /// The banner is about a *current* write that is not landing. Once nothing
    /// is forced any more there is no write to fail, and leaving the flag set
    /// left "Fan speed write did not take effect" on screen for the rest of the
    /// session after the user had already put every fan back on Auto.
    private func clearWriteFailureIfIdle() {
        if controlWriteFailed, !fanForcedActive.values.contains(true) { controlWriteFailed = false }
    }

    /// The helper answers whether the SMC write landed; discarding that answer
    /// is how a UI ends up showing a target RPM nothing ever applied.
    private func applyControlResult(fan: Int, outcome: HelperClient.HoldOutcome) {
        // Only an SMC refusal earns the banner. An unreachable daemon is the
        // helper pill's and the helper-not-installed banner's story, and blaming
        // the SMC for it would be simply untrue.
        let refused = outcome == .refused
        if controlWriteFailed != refused { controlWriteFailed = refused }
        // A failed send still recorded the target as sent, so hysteresis would
        // suppress the retry until the next heartbeat. Forget it and let the
        // next decision re-send immediately.
        if outcome != .applied { lastSentRPM.removeValue(forKey: fan) }
    }

    // MARK: - UI-facing mutations

    /// `resend: false` keeps hysteresis in charge — for continuous edits like a
    /// slider drag, where forcing a send per step means a helper round-trip and
    /// two root SMC writes for every one of the dozens of steps in one gesture.
    func updateFanConfig(_ index: Int, resend: Bool = true, _ mutate: (inout FanConfig) -> Void) {
        var config = settings.fanConfig(for: index)
        mutate(&config)
        settings.setFanConfig(config, for: index)
        // Respond promptly to user edits.
        if resend { lastSentRPM.removeValue(forKey: index) }
        controlDecide()
    }

    /// Push this fan's current target out now, whatever hysteresis says — used
    /// when a drag ends, so the value under the user's finger is the one applied.
    func resendFan(_ index: Int) {
        lastSentRPM.removeValue(forKey: index)
        controlDecide()
    }

    func applyPreset(_ index: Int, curve: [CurvePoint]) {
        updateFanConfig(index) {
            $0.mode = .curve
            $0.curve = curve.map { CurvePoint(temp: $0.temp, percent: $0.percent) }
        }
    }

    func restoreAutoAll() {
        for fan in fans { updateFanConfig(fan.index) { $0.mode = .auto } }
        lastSentRPM.removeAll()
        fanForcedActive.removeAll()
        controlWriteFailed = false
        endControlActivity()
        helperQueue.async { HelperClient.shared.autoAll() }
    }

    // MARK: - privileged helper

    func refreshHelperStatus() {
        helperQueue.async {
            let version = HelperClient.shared.probe()
            Task { @MainActor in self.applyHelperProbe(version) }
        }
    }

    /// Same probe, awaited. `refreshHelperStatus` leaves the answer arriving one
    /// hop later, which is no use to a caller that is about to decide something.
    private func probeHelperNow() async {
        let version = await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            helperQueue.async { continuation.resume(returning: HelperClient.shared.probe()) }
        }
        applyHelperProbe(version)
    }

    private func applyHelperProbe(_ version: Int?) {
        let ok = version != nil
        if helperAvailable != ok {
            helperAvailable = ok
            // A failure note that outlived its subject: the helper's presence has
            // changed under it, so it can only confuse. An outcome still inside
            // its own expiry window is fresh feedback and is left alone.
            if noteExpiry == nil { installer.clearNote() }
        }
        if helperVersion != version { helperVersion = version }
    }

    /// A daemon left over from an older FanGlass. launchd keeps whatever is on
    /// disk running, so only an explicit reinstall replaces it.
    var helperOutdated: Bool {
        guard let helperVersion else { return false }
        return helperVersion < HelperProtocol.version
    }

    /// Runs `work` immediately — the highlight must show what the user chose
    /// even if they decline the password dialog — and, when there is no helper
    /// to carry it out, offers to install one and replays the intent on success.
    func requireHelper(_ reason: HelperInstaller.Reason, then work: @escaping () -> Void) {
        work()
        guard !helperAvailable else { return }
        pendingIntent = work
        requestHelperInstall(reason: reason)
    }

    /// The one entry point to the authorization prompt. Uses the sheet when the
    /// main window is on screen and an NSAlert otherwise: at first launch there
    /// is no window at all, and a MenuBarExtra panel dismisses itself as soon as
    /// the password dialog takes focus.
    func requestHelperInstall(reason: HelperInstaller.Reason) {
        guard !installer.isBusy, !showInstallSheet, !promptOnScreen else { return }
        installReason = reason
        installer.clearNote()
        if NSApp.windows.contains(where: { AppDelegate.isMainWindow($0) && $0.isVisible }) {
            AppDelegate.presentMainWindow()
            showInstallSheet = true
        } else {
            presentInstallAlert(reason: reason)
        }
    }

    /// Starts the privileged install. The sheet, the Settings card and the
    /// NSAlert all route their outcome through here.
    func beginInstall() {
        installer.install { [weak self] version in
            guard let self else { return }
            let intent = pendingIntent
            pendingIntent = nil
            if let version {
                prePromptHelperVersion = nil
                applyHelperProbe(version)
                showInstallSheet = false
                intent?()          // replay what the user picked before installing
                reconcileHelperHolds()   // a fresh daemon may already hold fans
                controlDecide()
            } else {
                // A failed update must not consume the one prompt this protocol
                // version gets: the machine is now in the state the prompt was
                // trying to fix. Dismissing the password dialog counts the same —
                // that answers nothing, so offer the update again next launch.
                // Only "Later" keeps the bump (see `cancelInstallRequest`).
                if installPhase.isProblem, let previous = prePromptHelperVersion {
                    settings.lastPromptedHelperVersion = previous
                }
                prePromptHelperVersion = nil
                refreshHelperStatus()
                // The NSAlert path has no window left to show the error in.
                if !showInstallSheet, case .failed(let message) = installPhase {
                    presentFailureAlert(message)
                }
            }
        }
    }

    func uninstallHelper() {
        installer.uninstall { [weak self] _ in self?.refreshHelperStatus() }
    }

    /// "Later" — keep the user's choice highlighted, just stop asking for now.
    func cancelInstallRequest() {
        pendingIntent = nil
        showInstallSheet = false
        // Declining keeps the version bump: the user answered the question, and
        // asking again every launch is not a better answer. Dropping the rollback
        // record also stops a later, unrelated manual install from undoing it.
        prePromptHelperVersion = nil
    }

    /// Any dismissal of the onboarding sheet — Later, Escape, or SwiftUI tearing
    /// it down — must drop the intent it captured, or a much later install would
    /// replay a choice the user has long forgotten. An install in flight is
    /// exempt: `beginInstall` moves the intent out itself and replays it there.
    func installSheetDismissed() {
        guard !installPhase.isBusy else { return }
        cancelInstallRequest()
    }

    /// Terminal phases are a report on something that just happened, not state:
    /// left alone, the Settings card still reads "Helper installed and connected",
    /// next to a live detail line that may by then say something else.
    private func scheduleNoteExpiry(for phase: HelperInstaller.Phase) {
        noteExpiry?.cancel()
        noteExpiry = nil
        // .failed carries a diagnostic worth reading at the user's own pace;
        // only the routine outcomes expire on a timer.
        switch phase {
        case .installed, .uninstalled, .canceled: break
        default: return
        }
        noteExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.installer.clearNote()
        }
    }

    private func promptForHelperIfNeeded() {
        let reason: HelperInstaller.Reason
        if !helperAvailable {
            guard !settings.helperOnboardingShown else { return }
            reason = .firstLaunch
        } else if helperOutdated {
            guard settings.lastPromptedHelperVersion < HelperProtocol.version else { return }
            reason = .outdated   // never reinstall on our own; it costs a password
        } else {
            return
        }
        // Let the launch settle first: the menu-bar icon should be on screen
        // before a modal takes over, and NSAlert mid-launch is fragile.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            // `init`'s single probe can predate launchd binding the socket — the
            // normal race right after a reboot when FanGlass is a login item.
            // Asking for a password for a helper that is already there would be
            // bad enough; burning the one-shot flag on it is worse, so both the
            // condition and the flags wait until the prompt is really going up.
            await self.probeHelperNow()
            switch reason {
            case .firstLaunch:
                guard !self.helperAvailable, !self.settings.helperOnboardingShown else { return }
                self.settings.helperOnboardingShown = true   // offered once, whatever the outcome
            case .outdated:
                guard self.helperOutdated,
                      self.settings.lastPromptedHelperVersion < HelperProtocol.version else { return }
                self.prePromptHelperVersion = self.settings.lastPromptedHelperVersion
                self.settings.lastPromptedHelperVersion = HelperProtocol.version
            default:
                return
            }
            self.requestHelperInstall(reason: reason)
        }
    }

    private func presentInstallAlert(reason: HelperInstaller.Reason) {
        // Claimed synchronously, released in the Task's defer: `runModal` spins a
        // nested run loop that still drains the main queue, so the sleeping
        // first-launch Task could resume *inside* the first alert and stack a
        // second one for the same intent. `installer.isBusy` does not cover this
        // window — nothing is installing yet.
        promptOnScreen = true
        // Off the current turn, because this is reached synchronously from a
        // picker's `withAnimation { ... }` closure; entering an AppKit modal
        // loop with a SwiftUI transaction still open is asking for trouble.
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.promptOnScreen = false }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = reason.title
            // The sheet spells out that the helper is removable; the alert is the
            // only thing the user sees on first launch, which is exactly when an
            // admin password is being asked for, so it must say the same.
            alert.informativeText = reason.message + "\n\n" + HelperInstaller.Reason.uninstallNote
            alert.alertStyle = .informational
            alert.addButton(withTitle: reason.confirmTitle)
            alert.addButton(withTitle: String(localized: "Later"))
            if alert.runModal() == .alertFirstButtonReturn {
                self.beginInstall()
            } else {
                self.cancelInstallRequest()
            }
        }
    }

    private func presentFailureAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Helper installation did not complete")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    // MARK: - overheat alerts

    private func checkOverheat() {
        let threshold = settings.overheatThreshold
        // Stale values are still on screen while sensors are down; they must
        // not keep firing an alert every two minutes.
        guard threshold > 0, !sensorsUnavailable else { return }
        let hottest = hottestTemperature
        guard hottest >= threshold else { return }
        guard Date().timeIntervalSince(lastOverheatAlert) > 120 else { return }
        lastOverheatAlert = Date()
        let content = UNMutableNotificationContent()
        content.title = String(localized: "FanGlass overheat alert")
        content.body = String(format: String(localized: "The hottest sensor has reached %.0f°C (threshold %.0f°C)"),
                              hottest, threshold)
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - launch at login

    func applyLaunchAtLogin() {
        do {
            if settings.launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            // Ad-hoc signed builds may be rejected; leave the toggle as-is.
        }
    }

    // MARK: - persistence

    /// Persist ~0.5 s after the last change. Every slider in Settings writes
    /// through `settings`, so a single drag used to mean dozens of synchronous
    /// pretty-printed encodes and atomic file writes on the main thread.
    private func scheduleSettingsSave() {
        pendingSave?.cancel()
        let snapshot = settings
        let item = DispatchWorkItem { SettingsStore.save(snapshot) }
        pendingSave = item
        saveQueue.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Write a debounced change out now. Called on the way to termination —
    /// the process must not exit with the last half-second of edits unsaved.
    private func flushSettings() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = settings
        saveQueue.sync { SettingsStore.save(snapshot) }
    }

    // MARK: - quit handling

    /// Ordered shutdown, called from `applicationWillTerminate`.
    ///
    /// The order matters: a `hold` queued by the last control decision that
    /// arrived at the helper *after* `autoAll` would re-force the fan, and then
    /// only the 20 s watchdog would undo it — exactly what "Restore automatic fan
    /// control on quit" exists to prevent. Stopping the timers and draining it
    /// makes that deterministic instead of a race.
    func prepareForTermination() {
        shuttingDown = true
        pollTimer?.cancel()
        pollTimer = nil
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        endControlActivity()
        flushSettings()
        helperQueue.sync {}   // barrier: nothing left in flight
        if settings.restoreAutoOnQuit {
            HelperClient.shared.autoAll()
        }
    }

    // MARK: - display helpers

    var hottestTemperature: Double {
        loadGroups.map(\.value).max() ?? 0
    }

    /// The fastest fan — on a 2-fan MacBook Pro or Mac Pro, fan 0 alone would
    /// under-report the machine.
    var primaryFanRPM: Double {
        fans.map(\.actualRPM).max() ?? 0
    }

    func selection(forFan index: Int) -> FanSelection {
        settings.fanConfig(for: index).selection
    }

    /// The selection shared by EVERY fan, or nil when they disagree. Menu-bar
    /// quick modes apply to all fans at once, so nil means "highlight nothing".
    var selectionForAllFans: FanSelection? {
        guard let first = fans.first else { return nil }
        let s = selection(forFan: first.index)
        return fans.allSatisfy { selection(forFan: $0.index) == s } ? s : nil
    }

    /// One line shown when no quick-mode pill lights up, so the row is never
    /// unexplained. nil means a pill is lit and needs no caption.
    var quickModeHint: String? {
        guard !fans.isEmpty else { return nil }
        switch selectionForAllFans {
        case .auto, .preset: return nil
        case .customCurve:   return String(localized: "Currently on a custom curve")
        case .fixed:         return String(localized: "Currently on a fixed speed")
        case nil:            return fans.count > 1 ? String(localized: "Fans are set differently") : nil
        }
    }

    var allFansAuto: Bool {
        !fans.isEmpty && fans.allSatisfy { settings.fanConfig(for: $0.index).mode == .auto }
    }

    func group(id: String) -> SensorGroupState? {
        groups.first { $0.id == id }
    }

    func temperatureColor(_ value: Double) -> Color {
        switch value {
        case ..<50: return Color(red: 0.30, green: 0.75, blue: 0.95)
        case 50..<70: return Color(red: 0.35, green: 0.80, blue: 0.55)
        case 70..<85: return Color(red: 0.98, green: 0.72, blue: 0.25)
        default: return Color(red: 0.95, green: 0.35, blue: 0.30)
        }
    }
}
