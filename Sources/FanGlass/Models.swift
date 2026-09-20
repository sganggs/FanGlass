// Models.swift — settings, fan curve model, persistence.
import Foundation

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
    var title: String {
        switch self {
        case .auto: return "自动"
        case .fixed: return "固定转速"
        case .curve: return "曲线"
        }
    }
}

struct FanConfig: Codable, Equatable {
    var mode: FanControlMode = .auto
    var fixedPercent: Double = 45
    var curve: [CurvePoint] = FanConfig.defaultCurve

    static let defaultCurve: [CurvePoint] = [
        CurvePoint(temp: 30, percent: 0),
        CurvePoint(temp: 50, percent: 18),
        CurvePoint(temp: 65, percent: 42),
        CurvePoint(temp: 80, percent: 72),
        CurvePoint(temp: 92, percent: 100),
    ]

    /// Presets selectable in the UI.
    static let presets: [(name: String, curve: [CurvePoint])] = [
        ("静音", [
            CurvePoint(temp: 30, percent: 0), CurvePoint(temp: 60, percent: 10),
            CurvePoint(temp: 75, percent: 28), CurvePoint(temp: 88, percent: 60),
            CurvePoint(temp: 96, percent: 100),
        ]),
        ("均衡", FanConfig.defaultCurve),
        ("性能", [
            CurvePoint(temp: 30, percent: 25), CurvePoint(temp: 50, percent: 45),
            CurvePoint(temp: 65, percent: 70), CurvePoint(temp: 78, percent: 90),
            CurvePoint(temp: 88, percent: 100),
        ]),
        ("全速", [CurvePoint(temp: 0, percent: 100), CurvePoint(temp: 100, percent: 100)]),
    ]
}

struct AppSettings: Codable {
    var pollInterval: Double = 1.0
    var hysteresisRPM: Double = 120
    var overheatThreshold: Double = 95      // °C; 0 disables alerts
    var controlSource: String = "cpu"       // sensor group id, or "max"
    var launchAtLogin: Bool = false
    var restoreAutoOnQuit: Bool = true
    var fans: [String: FanConfig] = [:]     // fan index (as string) → config

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
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    static func save(_ settings: AppSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
