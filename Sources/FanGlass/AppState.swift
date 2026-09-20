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
    @Published private(set) var targetRPMs: [Int: Double] = [:]
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

    // Control bookkeeping (MainActor only).
    private var lastSentRPM: [Int: Double] = [:]
    private var lastSentTime: [Int: Date] = [:]
    private var fanForcedActive: [Int: Bool] = [:]
    private var lastOverheatAlert = Date.distantPast
    private var pollTimer: DispatchSourceTimer?

    /// Read by AppDelegate on termination (must stay nonisolated).
    nonisolated(unsafe) static var restoreAutoOnQuitFlag = true

    init() {
        settings = SettingsStore.load()
        AppState.restoreAutoOnQuitFlag = settings.restoreAutoOnQuit
        helperAvailable = HelperClient.shared.isAvailable
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        applyLaunchAtLogin()
        worker.async { [weak self] in self?.bootstrap() }
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

    func refreshHelperStatus() {
        worker.async {
            let ok = HelperClient.shared.isAvailable
            Task { @MainActor in self.helperAvailable = ok }
        }
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
