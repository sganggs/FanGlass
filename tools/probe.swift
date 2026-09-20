// probe.swift — dumps every SMC key on this Mac with its type and decoded value.
// Read-only; no privileges needed.
//
// Build it against the app's own SMC layer, so the diagnostic tool and the app
// can never disagree about the wire format:
//
//   swiftc -O -o build/probe tools/probe.swift Sources/Shared/SMC.swift -framework IOKit
//   ./build/probe            # everything
//   ./build/probe T          # only keys starting with T
//
// If a sensor on your Mac lands in the wrong group, paste the output into an
// issue — the per-chip key tables in AppState.classify() are built from exactly
// this kind of dump.
import Foundation

@main
struct Probe {
    static func main() {
        guard let smc = SMC.shared else {
            print("ERROR: cannot open AppleSMC")
            exit(1)
        }

        let filter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
        let keys = smc.allKeys().filter { filter.isEmpty || $0.hasPrefix(filter) }
        print("SMC keys: \(keys.count)\(filter.isEmpty ? "" : " (prefix \(filter))")\n")

        var histogram: [String: Int] = [:]
        var rows: [(key: String, type: String, value: String)] = []
        for key in keys {
            guard let (type, bytes) = try? smc.readKey(key) else { continue }
            histogram[type, default: 0] += 1
            rows.append((key, type, describe(type, bytes)))
        }

        section("FANS", rows.filter { $0.key.hasPrefix("F") })
        section("TEMPERATURES", rows.filter { $0.key.hasPrefix("T") })
        section("POWER / VOLTAGE / CURRENT", rows.filter { "PVI".contains($0.key.first ?? " ") })
        section("OTHER", rows.filter { !"FTPVI".contains($0.key.first ?? " ") })

        print("=== TYPE HISTOGRAM ===")
        for (type, count) in histogram.sorted(by: { $0.value > $1.value }) {
            print("  [\(type)] x\(count)")
        }
        print("")
        print("Fans reported by FNum: \(smc.fanCount())")
        print("Fan control supported: \(smc.fanControlSupported())")
    }

    static func section(_ title: String, _ items: [(key: String, type: String, value: String)]) {
        guard !items.isEmpty else { return }
        print("=== \(title) (\(items.count)) ===")
        for r in items.sorted(by: { $0.key < $1.key }) {
            print("  \(r.key)  [\(r.type)]  \(r.value)")
        }
        print("")
    }

    /// Values SMC.readFloat deliberately does not decode still say something
    /// useful here (strings, flags, raw bytes), so the diagnostic view is richer
    /// than the app's.
    static func describe(_ type: String, _ bytes: [UInt8]) -> String {
        if let v = SMC.decodeNumber(type: type, bytes: bytes) {
            return String(format: "%.2f", v)
        }
        switch type {
        case "flag":
            return bytes.first == 0 ? "false" : "true"
        case "ch8*":
            return String(bytes: bytes.prefix { $0 >= 0x20 && $0 < 0x7f }, encoding: .ascii) ?? "-"
        case "ioft" where bytes.count == 8:
            // 8-byte fixed point. The scaling is unverified — shown raw on purpose.
            var u: UInt64 = 0
            for i in (0..<8).reversed() { u = (u << 8) | UInt64(bytes[i]) }
            return "raw \(u)"
        default:
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
    }
}
