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
    let id: String
    let name: String
    var keys: [String]
    var value: Double = 0
    var history: [SensorSample] = []
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
            SettingsStore.save(settings)
            AppState.restoreAutoOnQuitFlag = settings.restoreAutoOnQuit
        }
    }

    // Worker-only state (serial queue → data-race safe by construction).
    nonisolated private let worker = DispatchQueue(label: "fanglass.worker", qos: .userInitiated)
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

    // Privileged-helper install flow.
    let installer = HelperInstaller()
    /// What the user asked for while no helper was installed, replayed once one is.
    private var pendingIntent: (() -> Void)?

    /// Read by AppDelegate on termination (must stay nonisolated).
    nonisolated(unsafe) static var restoreAutoOnQuitFlag = true

    init() {
        settings = SettingsStore.load()
        AppState.restoreAutoOnQuitFlag = settings.restoreAutoOnQuit
        let version = HelperClient.shared.probe()
        helperAvailable = version != nil
        helperVersion = version
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        applyLaunchAtLogin()
        installer.onPhaseChange = { [weak self] phase in self?.installPhase = phase }
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
        pollTimer?.cancel()
        pollTimer = nil
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
        var classified: [(id: String, name: String, key: String, value: Double?)] = []
        for key in keys where key.hasPrefix("T") {
            guard let raw = smc.readFloat(key), let c = AppState.classify(key: key) else { continue }
            classified.append((c.id, c.name, key, AppState.plausible(raw) ? raw : nil))
        }
        var order: [String] = []
        var byID: [String: SensorGroupState] = [:]
        var evidence: Set<String> = []   // groups that produced a real reading
        for item in classified {
            if byID[item.id] == nil {
                byID[item.id] = SensorGroupState(id: item.id, name: item.name, keys: [])
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
            self.promptForHelperIfNeeded()
        }
    }

    /// A sensor reading worth trusting. The upper bound is generous enough for
    /// Intel package sensors near TjMax; the lower one drops power-gated blocks
    /// that report 0 °C while their domain is asleep.
    nonisolated static func plausible(_ value: Double) -> Bool { value > 5 && value < 150 }

    /// SMC key prefix → sensor group. Apple moves the core sensors to a new key
    /// family every few chip generations, so the table names the generation each
    /// rule is for; anything unrecognised lands in 其他 rather than being
    /// mislabelled as something it is not.
    ///   M1 / M2 / M4 / M5   CPU P-cores Tp*, E-cores Te*, GPU Tg*
    ///   M3                  CPU Tf0*/Tf4*, GPU Tf1*/Tf2*  (no Tp*/Tg* at all)
    ///   Intel               CPU TC0*/TCA*, GPU TG0*
    nonisolated private static func classify(key: String) -> (id: String, name: String)? {
        if key == "TVA0" { return ("ambient", "环境") }
        if key.hasPrefix("Tp") { return ("cpu", "CPU") }
        if key.hasPrefix("Te") { return ("cpu", "CPU") }        // efficiency cores (M3/M4)
        if key.hasPrefix("Tf") {
            // M3 splits CPU and GPU by the second nibble. M4's TfC0/TfC1 are
            // neither and stay unclassified.
            switch key.dropFirst(2).first {
            case "0", "4": return ("cpu", "CPU")
            case "1", "2": return ("gpu", "GPU")
            default: return ("other", "其他")
            }
        }
        if key.hasPrefix("Tg") { return ("gpu", "GPU") }
        if key.hasPrefix("TC0") || key.hasPrefix("TCA") { return ("cpu", "CPU") }   // Intel
        if key.hasPrefix("TG0") { return ("gpu", "GPU") }                           // Intel
        if key.hasPrefix("Tm") { return ("memory", "内存") }
        if key.hasPrefix("Ts") { return ("system", "系统") }
        if ["TPD", "TRD", "TPS", "TVS", "TVV", "TVD", "TW0"].contains(where: key.hasPrefix) {
            return ("power", "电源")
        }
        if ["TH0", "TIE", "TSC", "TMV", "TUV", "TT0", "Ta0", "TN0", "TB0", "TA0"].contains(where: key.hasPrefix) {
            return ("system", "系统")
        }
        // TCM* is a composite/threshold sensor that tracks the hottest core;
        // grouping it under 系统 made 系统 read like a second CPU number.
        return ("other", "其他")
    }

    // MARK: - polling

    private func startPolling() {
        helperCheckDivisor = max(1, Int((10.0 / max(0.1, settings.pollInterval)).rounded()))
        let t = DispatchSource.makeTimerSource(queue: worker)
        t.schedule(deadline: .now(), repeating: settings.pollInterval)
        t.setEventHandler { [weak self] in self?.pollOnce() }
        t.resume()
        pollTimer = t
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
            let version = HelperClient.shared.probe()
            Task { @MainActor in self.applyHelperProbe(version) }
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
        // clearing them would flash 未检测到风扇 and stall the control loop.
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
        return groups.filter { $0.id != "ambient" }.map(\.value).max()
    }

    var controlTemperature: Double { controlTemperatureValue ?? 0 }

    /// True when the saved control source has no matching group on this Mac.
    var controlSourceMissing: Bool {
        let id = settings.controlSource
        return id != "max" && !groups.isEmpty && !groups.contains { $0.id == id }
    }

    private func controlDecide() {
        // Nothing to decide without a helper to carry it out, or on hardware
        // that has no writable fan target — a saved config copied from another
        // Mac must not make the helper hammer the SMC once a second.
        guard helperAvailable, fanControlSupported else { return }
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
                let rpm = fan.minRPM + max(0, min(100, pct)) / 100 * (fan.maxRPM - fan.minRPM)
                sendHold(fan: fan.index, rpm: rpm)
            }
        }
    }

    private func sendHold(fan: Int, rpm: Double) {
        let last = lastSentRPM[fan] ?? .greatestFiniteMagnitude
        let lastTime = lastSentTime[fan] ?? .distantPast
        let changed = abs(rpm - last) >= settings.hysteresisRPM
        let heartbeat = Date().timeIntervalSince(lastTime) > 5
        if changed || heartbeat {
            lastSentRPM[fan] = rpm
            lastSentTime[fan] = Date()
            fanForcedActive[fan] = true
            worker.async { [weak self] in
                let ok = HelperClient.shared.hold(fan: fan, rpm: rpm)
                Task { @MainActor in self?.applyControlResult(ok) }
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
        worker.async { HelperClient.shared.auto(fan: fan) }
    }

    /// The helper answers whether the SMC write landed; discarding that answer
    /// is how a UI ends up showing a target RPM nothing ever applied.
    private func applyControlResult(_ ok: Bool) {
        if controlWriteFailed != !ok { controlWriteFailed = !ok }
    }

    // MARK: - UI-facing mutations

    func updateFanConfig(_ index: Int, _ mutate: (inout FanConfig) -> Void) {
        var config = settings.fanConfig(for: index)
        mutate(&config)
        settings.setFanConfig(config, for: index)
        // Respond promptly to user edits.
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
        worker.async { HelperClient.shared.autoAll() }
    }

    // MARK: - privileged helper

    func refreshHelperStatus() {
        worker.async {
            let version = HelperClient.shared.probe()
            Task { @MainActor in self.applyHelperProbe(version) }
        }
    }

    private func applyHelperProbe(_ version: Int?) {
        let ok = version != nil
        if helperAvailable != ok { helperAvailable = ok }
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
        guard !installer.isBusy, !showInstallSheet else { return }
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
                applyHelperProbe(version)
                showInstallSheet = false
                intent?()          // replay what the user picked before installing
                controlDecide()
            } else {
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

    /// "稍后" — keep the user's choice highlighted, just stop asking for now.
    func cancelInstallRequest() {
        pendingIntent = nil
        showInstallSheet = false
    }

    private func promptForHelperIfNeeded() {
        let reason: HelperInstaller.Reason
        if !helperAvailable {
            guard !settings.helperOnboardingShown else { return }
            settings.helperOnboardingShown = true   // offered once, whatever the outcome
            reason = .firstLaunch
        } else if helperOutdated {
            guard settings.lastPromptedHelperVersion < HelperProtocol.version else { return }
            settings.lastPromptedHelperVersion = HelperProtocol.version
            reason = .outdated   // never reinstall on our own; it costs a password
        } else {
            return
        }
        // Let the launch settle first: the menu-bar icon should be on screen
        // before a modal takes over, and NSAlert mid-launch is fragile.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.requestHelperInstall(reason: reason)
        }
    }

    private func presentInstallAlert(reason: HelperInstaller.Reason) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = reason.title
        alert.informativeText = reason.message
        alert.alertStyle = .informational
        alert.addButton(withTitle: reason.confirmTitle)
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            beginInstall()
        } else {
            cancelInstallRequest()
        }
    }

    private func presentFailureAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "助手安装未完成"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
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
        content.title = "FanGlass 过热提醒"
        content.body = String(format: "传感器最高温度已达 %.0f°C(阈值 %.0f°C)", hottest, threshold)
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

    // MARK: - quit handling

    func handleQuit() {
        if settings.restoreAutoOnQuit {
            HelperClient.shared.autoAll()
        }
    }

    // MARK: - display helpers

    var hottestTemperature: Double {
        groups.filter { $0.id != "ambient" }.map(\.value).max() ?? 0
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
        case .customCurve:   return "当前为自定义曲线"
        case .fixed:         return "当前为固定转速"
        case nil:            return fans.count > 1 ? "各风扇设置不同" : nil
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
