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
        var classified: [(id: String, name: String, key: String, value: Double)] = []
        for key in keys where key.hasPrefix("T") {
            guard let value = smc.readFloat(key), value > 5, value < 120 else { continue }
            if let c = AppState.classify(key: key) {
                classified.append((c.id, c.name, key, value))
            }
        }
        var groups: [SensorGroupState] = []
        for item in classified {
            if let idx = groups.firstIndex(where: { $0.id == item.id }) {
                groups[idx].keys.append(item.key)
                groups[idx].value = max(groups[idx].value, item.value)
            } else {
                groups.append(SensorGroupState(id: item.id, name: item.name, keys: [item.key], value: item.value))
            }
        }
        let priority = ["cpu": 0, "gpu": 1, "soc": 2, "storage": 3, "memory": 4, "power": 5, "ambient": 6, "system": 7, "other": 8]
        groups.sort { (priority[$0.id] ?? 9) < (priority[$1.id] ?? 9) }

        let fanCount = smc.fanCount()
        let fanStatuses = (0..<fanCount).compactMap { smc.fanStatus($0) }
        scanSnapshot = groups.map { ($0.id, $0.keys) }
        fanCountSnapshot = fanCount

        Task { @MainActor in
            self.groups = groups
            self.fans = fanStatuses
            self.scanning = false
            self.startPolling()
            self.promptForHelperIfNeeded()
        }
    }

    nonisolated private static func classify(key: String) -> (id: String, name: String)? {
        if key == "TVA0" { return ("ambient", "环境") }
        if key.hasPrefix("Tp") { return ("cpu", "CPU") }
        if key.hasPrefix("Tg") { return ("gpu", "GPU") }
        if key.hasPrefix("Te") { return ("soc", "SoC") }
        if key.hasPrefix("Ts") { return ("storage", "存储") }
        if key.hasPrefix("Tm") { return ("memory", "内存") }
        if ["TPD", "TRD", "TPS", "TVS", "TVV", "TVD", "TW0"].contains(where: key.hasPrefix) {
            return ("power", "电源")
        }
        if ["TH0", "TIE", "TSC", "TCM", "TMV", "TUV", "TT0", "Ta0"].contains(where: key.hasPrefix) {
            return ("system", "系统")
        }
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
            var best = 0.0
            for key in keys {
                if let v = smc.readFloat(key) { best = max(best, v) }
            }
            newValues[id] = best
        }
        let fanStatuses = (0..<fanCountSnapshot).compactMap { smc.fanStatus($0) }

        Task { @MainActor in
            self.applyPollResults(sensorValues: newValues, fanStatuses: fanStatuses)
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

    private func applyPollResults(sensorValues: [String: Double], fanStatuses: [FanStatus]) {
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
        fans = fanStatuses
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

    var controlTemperature: Double {
        if settings.controlSource == "max" {
            return groups.filter { $0.id != "ambient" }.map(\.value).max() ?? 0
        }
        return groups.first(where: { $0.id == settings.controlSource })?.value
            ?? groups.map(\.value).max() ?? 0
    }

    private func controlDecide() {
        guard helperAvailable else { return }
        for fan in fans {
            let config = settings.fanConfig(for: fan.index)
            switch config.mode {
            case .auto:
                if fanForcedActive[fan.index] == true {
                    fanForcedActive[fan.index] = false
                    lastSentRPM.removeValue(forKey: fan.index)
                    worker.async { HelperClient.shared.auto(fan: fan.index) }
                }
                targetRPMs[fan.index] = 0

            case .fixed:
                let rpm = fan.minRPM + config.fixedPercent / 100 * (fan.maxRPM - fan.minRPM)
                sendHold(fan: fan.index, rpm: rpm)

            case .curve:
                let pct = CurveMath.evaluate(
                    xs: config.curve.map(\.temp),
                    ys: config.curve.map(\.percent),
                    x: controlTemperature
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
            worker.async { HelperClient.shared.hold(fan: fan, rpm: rpm) }
        }
        targetRPMs[fan] = rpm
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
        guard threshold > 0 else { return }
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

    var primaryFanRPM: Double {
        fans.first?.actualRPM ?? 0
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
