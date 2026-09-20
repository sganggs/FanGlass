// Models.swift — settings, fan curve model, persistence.
import Foundation

extension Double {
    /// Range-check a value read from disk. NaN/infinity fail every comparison,
    /// so they are caught here rather than reaching the fan control loop.
    func clamped(to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard isFinite else { return fallback }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Fan curve

struct CurvePoint: Codable, Equatable, Identifiable {
    var id = UUID()
    var temp: Double    // °C
    var percent: Double // 0...100 of the fan's RPM range

    // Tolerate a missing id when decoding hand-edited config files.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        temp = try c.decode(Double.self, forKey: .temp)
        percent = try c.decode(Double.self, forKey: .percent)
    }

    init(id: UUID = UUID(), temp: Double, percent: Double) {
        self.id = id
        self.temp = temp
        self.percent = percent
    }
}

/// Monotone cubic (Fritsch–Carlson / PCHIP) interpolation.
/// `xs` must be strictly increasing; result is clamped to the end values outside the range.
enum CurveMath {
    static func evaluate(xs: [Double], ys: [Double], x: Double) -> Double {
        let n = xs.count
        if n == 0 { return 0 }
        if n == 1 { return ys[0] }
        if x <= xs[0] { return ys[0] }
        if x >= xs[n - 1] { return ys[n - 1] }

        var h = [Double](repeating: 0, count: n - 1)
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            h[i] = xs[i + 1] - xs[i]
            // Duplicate X (hand-edited settings) would divide by zero.
            if h[i] <= 1e-9 { h[i] = 1e-9 }
            d[i] = (ys[i + 1] - ys[i]) / h[i]
        }

        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) {
            if d[i - 1] * d[i] <= 0 {
                m[i] = 0
            } else {
                let w1 = 2 * h[i] + h[i - 1]
                let w2 = h[i] + 2 * h[i - 1]
                m[i] = (w1 + w2) / (w1 / d[i - 1] + w2 / d[i])
            }
        }

        var i = 0
        while i < n - 2 && x > xs[i + 1] { i += 1 }
        let t = (x - xs[i]) / h[i]
        let t2 = t * t, t3 = t2 * t
        return ys[i] * (2 * t3 - 3 * t2 + 1)
             + h[i] * m[i] * (t3 - 2 * t2 + t)
             + ys[i + 1] * (-2 * t3 + 3 * t2)
             + h[i] * m[i + 1] * (t3 - t2)
    }
}

// MARK: - Settings

enum FanControlMode: String, Codable, CaseIterable, Identifiable {
    case auto, fixed, curve
    var id: String { rawValue }
    /// Flows through a plain `String` (LiquidSegmentedPicker takes titles, not
    /// keys), so it has to be localized here rather than by SwiftUI.
    var title: String {
        switch self {
        case .auto: return String(localized: "Auto")
        case .fixed: return String(localized: "Fixed")
        case .curve: return String(localized: "Curve")
        }
    }
}

struct FanConfig: Codable, Equatable {
    var mode: FanControlMode = .auto
    var fixedPercent: Double = 45
    var curve: [CurvePoint] = FanConfig.defaultCurve

    init() {}

    /// Lenient like `AppSettings.init(from:)` — and for the same reason. A
    /// throw here propagates all the way out of `SettingsStore.load()` and
    /// takes every other fan's curve down with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FanConfig()
        mode = try c.decodeIfPresent(FanControlMode.self, forKey: .mode) ?? d.mode
        fixedPercent = (try c.decodeIfPresent(Double.self, forKey: .fixedPercent) ?? d.fixedPercent)
            .clamped(to: 0...100, fallback: d.fixedPercent)
        let decoded = try c.decodeIfPresent([CurvePoint].self, forKey: .curve) ?? d.curve
        curve = FanConfig.sanitized(decoded)
    }

    /// What every consumer of a curve is entitled to assume: at least two
    /// points, finite values, percents in range, temps strictly increasing.
    /// `CurveMath` documents strictly-increasing x, and nothing else enforces
    /// it — the editor sorts its own draft, but a file written by another
    /// build (or by hand) reaches `controlDecide` untouched.
    static func sanitized(_ points: [CurvePoint]) -> [CurvePoint] {
        var out: [CurvePoint] = []
        for p in points.sorted(by: { $0.temp < $1.temp }) {
            guard p.temp.isFinite, p.percent.isFinite else { continue }
            let point = CurvePoint(id: p.id, temp: p.temp,
                                   percent: p.percent.clamped(to: 0...100, fallback: 0))
            // Duplicate temps make the PCHIP slopes explode; keep the last.
            if let last = out.last, point.temp - last.temp < 0.5 { out[out.count - 1] = point }
            else { out.append(point) }
        }
        return out.count >= 2 ? out : FanConfig.defaultCurve
    }

    static let defaultCurve: [CurvePoint] = [
        CurvePoint(temp: 30, percent: 0),
        CurvePoint(temp: 50, percent: 18),
        CurvePoint(temp: 65, percent: 42),
        CurvePoint(temp: 80, percent: 72),
        CurvePoint(temp: 92, percent: 100),
    ]

    /// Presets selectable in the UI.
    static let presets: [FanPreset] = [
        FanPreset(id: "quiet", curve: [
            CurvePoint(temp: 30, percent: 0), CurvePoint(temp: 60, percent: 10),
            CurvePoint(temp: 75, percent: 28), CurvePoint(temp: 88, percent: 60),
            CurvePoint(temp: 96, percent: 100),
        ]),
        FanPreset(id: "balanced", curve: FanConfig.defaultCurve),
        FanPreset(id: "performance", curve: [
            CurvePoint(temp: 30, percent: 25), CurvePoint(temp: 50, percent: 45),
            CurvePoint(temp: 65, percent: 70), CurvePoint(temp: 78, percent: 90),
            CurvePoint(temp: 88, percent: 100),
        ]),
        FanPreset(id: "max", curve: [CurvePoint(temp: 0, percent: 100),
                                     CurvePoint(temp: 100, percent: 100)]),
    ]
}

/// A curve preset. The `id` is the stable identity everything compares and
/// persists against; `title` is display-only and changes with the UI language,
/// so it must never be used to decide which preset a fan is on.
struct FanPreset: Identifiable, Equatable {
    let id: String
    let curve: [CurvePoint]

    var title: String {
        switch id {
        case "quiet":       return String(localized: "Quiet")
        case "balanced":    return String(localized: "Balanced")
        case "performance": return String(localized: "Performance")
        default:            return String(localized: "Max")
        }
    }
}

// MARK: - Selection (what the UI highlights)

/// The option a fan is currently on. Derived from the saved config, never from
/// the last click, so the highlight survives relaunch and follows hand edits.
enum FanSelection: Equatable {
    case auto
    /// Carries the preset's stable id, never its localized title.
    case preset(String)
    case customCurve
    case fixed
}

extension FanConfig {
    /// Curve equality that ignores point identity. `CurvePoint` stores a `var id
    /// = UUID()` and `applyPreset` re-mints every point, so the synthesized
    /// `[CurvePoint] ==` is always false and can never match a preset.
    /// Pairwise is correct: presets are declared temp-ascending and the curve
    /// editor re-sorts after every mutation. The tolerance absorbs JSON float
    /// round-trips; a drag moves a point far more than 0.01.
    static func curveMatches(_ a: [CurvePoint], _ b: [CurvePoint]) -> Bool {
        guard a.count == b.count else { return false }
        for (p, q) in zip(a, b)
        where abs(p.temp - q.temp) > 0.01 || abs(p.percent - q.percent) > 0.01 {
            return false
        }
        return true
    }

    /// Stable id of the preset this curve equals, or nil once the user edited
    /// it. Deliberately the id and not the title: the title is localized, so
    /// matching on it would break the highlight the moment the UI language
    /// changed (and would compare a display string against saved data).
    var matchingPresetID: String? {
        FanConfig.presets.first { FanConfig.curveMatches($0.curve, curve) }?.id
    }

    /// A brand-new config is .auto, so the fact that defaultCurve IS the
    /// "balanced" preset only shows up once the fan is actually switched to
    /// curve mode.
    var selection: FanSelection {
        switch mode {
        case .auto:  return .auto
        case .fixed: return .fixed
        case .curve: return matchingPresetID.map(FanSelection.preset) ?? .customCurve
        }
    }
}

struct AppSettings: Codable {
    var pollInterval: Double = 1.0
    var hysteresisRPM: Double = 120
    var overheatThreshold: Double = 95      // °C; 0 disables alerts
    var controlSource: String = "cpu"       // sensor group id, or "max"
    var launchAtLogin: Bool = false
    var restoreAutoOnQuit: Bool = true
    var fans: [String: FanConfig] = [:]     // fan index (as string) → config
    /// The unprompted first-launch helper offer fires exactly once.
    var helperOnboardingShown: Bool = false
    /// Highest helper protocol version we have already offered to update to.
    var lastPromptedHelperVersion: Int = 0

    init() {}

    /// Decode every field leniently. Synthesized Codable throws on a key that a
    /// settings.json written by an older build does not have yet, and
    /// SettingsStore.load() turns any throw into "reset everything to defaults" —
    /// so adding a field would silently wipe the user's fan curves.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        // Clamp to the ranges the UI offers: a hand-edited (or corrupted) file
        // must not be able to set a 0 s poll interval or a negative threshold.
        pollInterval = (try c.decodeIfPresent(Double.self, forKey: .pollInterval) ?? d.pollInterval)
            .clamped(to: 0.5...3.0, fallback: d.pollInterval)
        hysteresisRPM = (try c.decodeIfPresent(Double.self, forKey: .hysteresisRPM) ?? d.hysteresisRPM)
            .clamped(to: 0...400, fallback: d.hysteresisRPM)
        overheatThreshold = (try c.decodeIfPresent(Double.self, forKey: .overheatThreshold) ?? d.overheatThreshold)
            .clamped(to: 0...110, fallback: d.overheatThreshold)
        controlSource = try c.decodeIfPresent(String.self, forKey: .controlSource) ?? d.controlSource
        // Retired group ids: "soc" was really the CPU efficiency cores and
        // "storage" was a guess at Ts*, which turned out not to be storage.
        if controlSource == "soc" { controlSource = "cpu" }
        if controlSource == "storage" { controlSource = "system" }
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        restoreAutoOnQuit = try c.decodeIfPresent(Bool.self, forKey: .restoreAutoOnQuit) ?? d.restoreAutoOnQuit
        fans = try c.decodeIfPresent([String: FanConfig].self, forKey: .fans) ?? d.fans
        helperOnboardingShown = try c.decodeIfPresent(Bool.self, forKey: .helperOnboardingShown) ?? d.helperOnboardingShown
        lastPromptedHelperVersion = try c.decodeIfPresent(Int.self, forKey: .lastPromptedHelperVersion) ?? d.lastPromptedHelperVersion
    }

    func fanConfig(for index: Int) -> FanConfig {
        fans[String(index)] ?? FanConfig()
    }

    mutating func setFanConfig(_ config: FanConfig, for index: Int) {
        fans[String(index)] = config
    }
}

// MARK: - Persistence

enum SettingsStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FanGlass", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var fileURL: URL { directory.appendingPathComponent("settings.json") }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL) else { return AppSettings() }
        if let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return settings
        }
        // Every field decodes leniently, so reaching here means the file is not
        // usable JSON at all. Keep it: silently replacing a file that holds
        // hand-tuned fan curves is not a reset the user can undo.
        let backup = directory.appendingPathComponent("settings.json.bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
        return AppSettings()
    }

    static func save(_ settings: AppSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
