// probe.swift — SMC key scanner for Apple Silicon / Intel Macs.
// Dumps every SMC key with its type and decoded value. Read-only.
import Foundation
import IOKit

// SMCParamStruct is an 80-byte buffer. Offsets (smcFanControl layout):
//   key        @ 0  (UInt32 BE)
//   vers       @ 4  (6 bytes)
//   pLimitData @ 10 (16 bytes)
//   keyInfo    @ 26 (dataSize@26 UInt32 BE, dataType@30 UInt32 BE, dataAttributes@34)
//              (some layouts swap dataSize/dataType — detected at runtime)
//   result     @ 38, status @ 39, data8 @ 40, data32 @ 44 (UInt32 BE), bytes @ 48..80
let kSMCReadKey: UInt8 = 5
let kSMCWriteKey: UInt8 = 6
let kSMCGetKeyFromIndex: UInt8 = 8
let kSMCHandleYPCEvent: UInt32 = 2

struct SMCConnection {
    var conn: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
    }

    func call(_ input: inout [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: 80)
        var outSize = 80
        let kr = input.withUnsafeMutableBytes { inPtr -> kern_return_t in
            output.withUnsafeMutableBytes { outPtr -> kern_return_t in
                IOConnectCallStructMethod(conn, kSMCHandleYPCEvent,
                                          inPtr.baseAddress, 80,
                                          outPtr.baseAddress, &outSize)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return output
    }

    static func keyCode(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for c in s.utf8 { v = (v << 8) | UInt32(c) }
        return v
    }

    static func keyString(_ v: UInt32) -> String {
        let chars: [UInt8] = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                              UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: chars, encoding: .ascii) ?? "????"
    }

    func readRaw(_ key: String) -> (data: [UInt8], type: String, size: Int)? {
        var buf = [UInt8](repeating: 0, count: 80)
        let kc = SMCConnection.keyCode(key)
        buf[0] = UInt8((kc >> 24) & 0xff); buf[1] = UInt8((kc >> 16) & 0xff)
        buf[2] = UInt8((kc >> 8) & 0xff);  buf[3] = UInt8(kc & 0xff)
        buf[40] = kSMCReadKey
        guard let out = call(&buf) else { return nil }
        guard out[38] == 0 else { return nil } // result != kSMCSuccess

        // Detect keyInfo layout: the dataType offset should hold printable ASCII.
        func printable(_ off: Int) -> Bool {
            (off..<off+4).allSatisfy { out[$0] >= 0x20 && out[$0] < 0x7f }
        }
        let sizeOff: Int
        let typeOff: Int
        let sizeA = Int(out[26]) << 24 | Int(out[27]) << 16 | Int(out[28]) << 8 | Int(out[29])
        let sizeB = Int(out[30]) << 24 | Int(out[31]) << 16 | Int(out[32]) << 8 | Int(out[33])
        if printable(30) && (1...32).contains(sizeA) { sizeOff = 26; typeOff = 30 }
        else if printable(26) && (1...32).contains(sizeB) { sizeOff = 30; typeOff = 26 }
        else { return nil }
        let size = sizeOff == 26 ? sizeA : sizeB
        let t = typeOff
        let typeRaw = UInt32(out[t]) << 24 | UInt32(out[t+1]) << 16 | UInt32(out[t+2]) << 8 | UInt32(out[t+3])
        let type = SMCConnection.keyString(typeRaw)
        return (Array(out[48..<48+size]), type, size)
    }

    func keyCount() -> Int {
        guard let r = readRaw("#KEY"), r.data.count >= 4 else { return 0 }
        return Int(r.data[0]) << 24 | Int(r.data[1]) << 16 | Int(r.data[2]) << 8 | Int(r.data[3])
    }

    func keyAtIndex(_ i: Int) -> String? {
        var buf = [UInt8](repeating: 0, count: 80)
        buf[40] = kSMCGetKeyFromIndex
        buf[44] = UInt8((i >> 24) & 0xff); buf[45] = UInt8((i >> 16) & 0xff)
        buf[46] = UInt8((i >> 8) & 0xff);  buf[47] = UInt8(i & 0xff)
        guard let out = call(&buf), out[38] == 0 else { return nil }
        let kc = UInt32(out[0]) << 24 | UInt32(out[1]) << 16 | UInt32(out[2]) << 8 | UInt32(out[3])
        return SMCConnection.keyString(kc)
    }
}

func decode(_ data: [UInt8], _ type: String) -> String {
    switch type {
    case "sp78":
        guard data.count >= 2 else { return "?" }
        let raw = Int16(data[0]) << 8 | Int16(data[1])
        return String(format: "%.2f", Double(raw) / 256.0)
    case "fpe2":
        guard data.count >= 2 else { return "?" }
        let raw = UInt16(data[0]) << 8 | UInt16(data[1])
        return String(format: "%.2f", Double(raw) / 4.0)
    case "flt ":
        guard data.count >= 4 else { return "?" }
        let le = data.withUnsafeBytes { $0.load(as: Float.self) } // host LE
        let beBytes = [data[3], data[2], data[1], data[0]]
        let be = beBytes.withUnsafeBytes { $0.load(as: Float.self) }
        if le.isFinite && abs(le) < 1e6 { return String(format: "%.2f (LE)", le) }
        if be.isFinite && abs(be) < 1e6 { return String(format: "%.2f (BE)", be) }
        return "?"
    case "ui8 ":
        return "\(data.first ?? 0)"
    case "ui16":
        guard data.count >= 2 else { return "?" }
        return "\(UInt16(data[0]) << 8 | UInt16(data[1]))"
    case "ui32":
        guard data.count >= 4 else { return "?" }
        return "\(UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3]))"
    case "ioft":
        let hex = data.map { String(format: "%02x", $0) }.joined()
        if data.count == 8 {
            let u = data.withUnsafeBytes { $0.load(as: UInt64.self) }
            let f = Float(u) / Float(UInt64(1) << 32)
            return String(format: "%.2f (hex %@)", f, hex)
        }
        return "hex " + hex
    default:
        if type.hasPrefix("ch8*") || type == "flag" {
            return data.map { $0 >= 0x20 && $0 < 0x7f ? Character(UnicodeScalar($0)) : "." }
                       .map(String.init).joined()
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}

guard let smc = SMCConnection() else {
    print("ERROR: cannot open AppleSMC")
    exit(1)
}

let count = smc.keyCount()
print("SMC key count: \(count)\n")

var fanKeys: [(String, String, String)] = []
var tempKeys: [(String, String, String)] = []
var otherInteresting: [(String, String, String)] = []

for i in 0..<count {
    guard let key = smc.keyAtIndex(i) else { continue }
    guard let r = smc.readRaw(key) else { continue }
    let val = decode(r.data, r.type)
    let entry = (key, r.type, val)
    if key.hasPrefix("F") || key.hasPrefix("f") { fanKeys.append(entry) }
    else if ["T", "t"].contains(key.first!) && (r.type == "sp78" || r.type == "flt " || r.type == "fpe2" || r.type == "ioft") {
        tempKeys.append(entry)
    }
    else if key.hasPrefix("P") && (r.type == "sp78" || r.type == "flt " || r.type == "ioft") {
        otherInteresting.append(entry)
    }
}

print("=== FAN KEYS ===")
for (k, t, v) in fanKeys { print("\(k)  [\(t)]  \(v)") }
print("\n=== TEMPERATURE KEYS (numeric T*) ===")
for (k, t, v) in tempKeys { print("\(k)  [\(t)]  \(v)") }
print("\n=== POWER-ish KEYS (numeric P*) ===")
for (k, t, v) in otherInteresting.prefix(40) { print("\(k)  [\(t)]  \(v)") }
