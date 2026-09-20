// SMC.swift — shared low-level SMC access (AppleSMC via IOKit).
//
// SMCParamStruct is an 80-byte buffer laid out by the C compiler under natural
// alignment. The offsets are IDENTICAL on x86_64 and arm64 — the struct holds
// UInt32 members, so pLimitData aligns to 12 and keyInfo to 28 on both:
//   key@0 (FourCharCode, stored reversed) · vers@4 · pLimitData@12
//   keyInfo@28 (dataSize@28, dataType@32, dataAttributes@36)
//   result@40 · status@41 · command data8@42 · data32@44 · value bytes@48..80
// (The "packed" reading of the same struct — keyInfo@26, result@38 — enumerates
// zero keys on every Mac. It is a bug, not an architecture difference.)
//
// Value byte order:
//   • `flt ` is a native little-endian IEEE float on both architectures.
//   • The legacy fixed-point types (sp78/sp87/fp88/fpe2) are big-endian, like
//     every other Mac SMC client decodes them (smcFanControl runs them through
//     ntohs). Intel Macs report every temperature as sp78 and every fan value
//     as fpe2, so getting this wrong blanks the whole dashboard there.
//   • The INTEGER types are genuinely mixed on Apple Silicon — measured on
//     Mac16,10: #KEY only makes sense big-endian, D1JA/DPBS/CLKT only
//     little-endian. There is no single convention, so integers are decoded
//     little-endian and anything implausible is filtered by the caller. The
//     fan path only depends on the 1-byte readUInt8, which is unaffected.
//
// Commands: 5=read, 6=write, 8=key-at-index, 9=key-info.
// Reads need no privileges; writes need root.
import Foundation
import IOKit

public enum SMCError: Error {
    case openFailed
    case callFailed(kern_return_t)
    case keyNotFound
    case badResult(UInt8)
    case badType
}

public final class SMC {
    public static let shared = SMC()
    private var conn: io_connect_t = 0
    private let lock = NSLock()

    private init?() {
        guard SMC.open(&conn) else { return nil }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    private static func open(_ conn: inout io_connect_t) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS
    }

    /// Re-open the IOKit connection. The handle can go stale across sleep/wake
    /// or when the service is re-matched, and every read then fails — which a
    /// caller must never mistake for "0 °C".
    @discardableResult
    public func reopen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if conn != 0 { IOServiceClose(conn); conn = 0 }
        return SMC.open(&conn)
    }

    // MARK: - primitive transport

    private func transport(_ input: inout [UInt8]) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        var output = [UInt8](repeating: 0, count: 80)
        var outSize = 80
        let kr = input.withUnsafeMutableBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                IOConnectCallStructMethod(conn, 2, inPtr.baseAddress, 80, outPtr.baseAddress, &outSize)
            }
        }
        guard kr == KERN_SUCCESS else { throw SMCError.callFailed(kr) }
        return output
    }

    private static func putKey(_ buf: inout [UInt8], _ key: String) {
        let c = Array(key.utf8)
        for i in 0..<4 { buf[i] = i < c.count ? c[3 - i] : 0 }
    }

    private static func keyString(_ b: ArraySlice<UInt8>) -> String {
        let a = Array(b)
        return String(bytes: [a[3], a[2], a[1], a[0]], encoding: .ascii) ?? "????"
    }

    // MARK: - key operations

    /// All SMC keys on this machine (via index enumeration).
    public func allKeys() -> [String] {
        var keys: [String] = []
        for i in 0..<5000 {
            var buf = [UInt8](repeating: 0, count: 80)
            buf[42] = 8 // kSMCGetKeyFromIndex
            let u = UInt32(i)
            buf[44] = UInt8(u & 0xff); buf[45] = UInt8((u >> 8) & 0xff)
            buf[46] = UInt8((u >> 16) & 0xff); buf[47] = UInt8((u >> 24) & 0xff)
            guard let out = try? transport(&buf), out[40] == 0 else { break }
            keys.append(SMC.keyString(out[0...3]))
        }
        return keys
    }

    /// Raw read: returns (type, valueBytes).
    public func readKey(_ key: String) throws -> (type: String, bytes: [UInt8]) {
        var info = [UInt8](repeating: 0, count: 80)
        SMC.putKey(&info, key)
        info[42] = 9 // kSMCGetKeyInfo
        let infoOut = try transport(&info)
        guard infoOut[40] == 0 else { throw SMCError.keyNotFound }
        let size = Int(infoOut[28]) | Int(infoOut[29]) << 8 | Int(infoOut[30]) << 16 | Int(infoOut[31]) << 24
        let type = SMC.keyString(infoOut[32...35])
        guard (1...32).contains(size) else { throw SMCError.badType }

        var buf = [UInt8](repeating: 0, count: 80)
        SMC.putKey(&buf, key)
        buf[28] = UInt8(size & 0xff); buf[29] = UInt8((size >> 8) & 0xff)
        buf[42] = 5 // kSMCReadKey
        let out = try transport(&buf)
        guard out[40] == 0 else { throw SMCError.badResult(out[40]) }
        return (type, Array(out[48..<48 + size]))
    }

    /// Raw write. Requires root.
    public func writeKey(_ key: String, bytes: [UInt8]) throws {
        var info = [UInt8](repeating: 0, count: 80)
        SMC.putKey(&info, key)
        info[42] = 9
        let infoOut = try transport(&info)
        guard infoOut[40] == 0 else { throw SMCError.keyNotFound }
        let size = Int(infoOut[28]) | Int(infoOut[29]) << 8 | Int(infoOut[30]) << 16 | Int(infoOut[31]) << 24
        guard size == bytes.count, (1...32).contains(size) else { throw SMCError.badType }

        var buf = [UInt8](repeating: 0, count: 80)
        SMC.putKey(&buf, key)
        buf[28] = UInt8(size & 0xff); buf[29] = UInt8((size >> 8) & 0xff)
        buf[42] = 6 // kSMCWriteKey
        for (i, b) in bytes.enumerated() { buf[48 + i] = b }
        let out = try transport(&buf)
        guard out[40] == 0 else { throw SMCError.badResult(out[40]) }
    }

    // MARK: - typed conveniences

    /// Numeric types this build can both read and write.
    public static let encodableTypes: Set<String> = ["flt ", "fpe2", "fp88", "sp78", "sp87", "ui8 ", "ui16"]

    public func readFloat(_ key: String) -> Double? {
        guard let (type, bytes) = try? readKey(key) else { return nil }
        return SMC.decodeNumber(type: type, bytes: bytes)
    }

    public static func decodeNumber(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "flt " where bytes.count == 4:
            // UInt8 buffers are 1-byte aligned; load Float via bitPattern.
            let bits = UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        // Legacy fixed point — big-endian (Intel temperatures and fan speeds).
        case "sp78" where bytes.count == 2:
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256.0
        case "sp87" where bytes.count == 2:
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 128.0
        case "fp88" where bytes.count == 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 256.0
        case "fpe2" where bytes.count == 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
        // Integers — little-endian (see the byte-order note at the top).
        case "ui8 " where bytes.count == 1:
            return Double(bytes[0])
        case "si8 " where bytes.count == 1:
            return Double(Int8(bitPattern: bytes[0]))
        case "ui16" where bytes.count == 2:
            return Double(UInt16(bytes[1]) << 8 | UInt16(bytes[0]))
        case "si16" where bytes.count == 2:
            return Double(Int16(bitPattern: UInt16(bytes[1]) << 8 | UInt16(bytes[0])))
        case "si32" where bytes.count == 4:
            let u = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Int32(bitPattern: u))
        default:
            // Deliberately not decoded: `ioft` (8-byte fixed point) reads ~0.0008
            // for TR0Z on Mac16,10, which is not a temperature in any scaling we
            // could verify — a guessed decoder would surface garbage as °C.
            return nil
        }
    }

    public func readUInt8(_ key: String) -> UInt8? {
        guard let (_, bytes) = try? readKey(key), let first = bytes.first else { return nil }
        return first
    }

    /// Write a number encoded the way the key itself declares it, so the same
    /// call works on a `flt ` target (Apple Silicon) and an `fpe2` one (Intel).
    /// Requires root.
    public func writeNumber(_ key: String, _ value: Double) -> Bool {
        guard let (type, bytes) = try? readKey(key) else { return false }
        let payload: [UInt8]
        switch type {
        case "flt " where bytes.count == 4:
            var f = Float(value)
            payload = withUnsafeBytes(of: &f) { Array($0) }   // native = little-endian
        case "fpe2" where bytes.count == 2:
            let raw = UInt16(max(0, min(16_383, value)) * 4)
            payload = [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case "fp88" where bytes.count == 2:
            let raw = UInt16(max(0, min(255, value)) * 256)
            payload = [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case "sp78" where bytes.count == 2:
            let raw = UInt16(bitPattern: Int16(max(-128, min(127, value)) * 256))
            payload = [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case "sp87" where bytes.count == 2:
            let raw = UInt16(bitPattern: Int16(max(-256, min(255, value)) * 128))
            payload = [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case "ui8 " where bytes.count == 1:
            payload = [UInt8(max(0, min(255, value)))]
        case "ui16" where bytes.count == 2:
            let raw = UInt16(max(0, min(65_535, value)))
            payload = [UInt8(raw & 0xff), UInt8(raw >> 8)]    // little-endian, as read
        default:
            return false
        }
        return (try? writeKey(key, bytes: payload)) != nil
    }

    public func writeUInt8(_ key: String, _ value: UInt8) -> Bool {
        (try? writeKey(key, bytes: [value])) != nil
    }
}

// MARK: - Fan model

public struct FanStatus: Codable, Sendable {
    public var index: Int
    public var actualRPM: Double
    public var minRPM: Double
    public var maxRPM: Double
    public var forced: Bool
}

public extension SMC {
    func fanCount() -> Int {
        Int(readUInt8("FNum") ?? 0)
    }

    func fanStatus(_ index: Int) -> FanStatus? {
        guard let actual = readFloat("F\(index)Ac"),
              let minR = readFloat("F\(index)Mn"),
              let maxR = readFloat("F\(index)Mx") else { return nil }
        return FanStatus(index: index, actualRPM: actual, minRPM: minR, maxRPM: maxR,
                         forced: forcedMode(index: index) ?? false)
    }

    /// Can this Mac be told to hold a fan speed at all? Checked without root:
    /// the target key must be a type we can encode, and one of the two manual
    /// mode mechanisms must exist. False on fanless Macs and on any model whose
    /// SMC exposes fans read-only — the UI says so instead of failing silently.
    func fanControlSupported() -> Bool {
        guard fanCount() > 0 else { return false }
        guard let target = try? readKey("F0Tg"), SMC.encodableTypes.contains(target.type) else { return false }
        return (try? readKey("F0Md")) != nil || forceMask() != nil
    }

    /// Force a target RPM (root only). Values are clamped to the fan's hardware range.
    func setFanForced(index: Int, rpm: Double) -> Bool {
        guard let minR = readFloat("F\(index)Mn"), let maxR = readFloat("F\(index)Mx") else { return false }
        let target = min(max(rpm, minR), maxR)
        // No `&&` short-circuit: a failed mode write must not hide whether the
        // target write also failed — the helper logs both.
        let modeOK = setForcedMode(index: index, forced: true)
        let targetOK = writeNumber("F\(index)Tg", target)
        return modeOK && targetOK
    }

    /// Return a fan to system automatic control (root only).
    func setFanAuto(index: Int) -> Bool {
        setForcedMode(index: index, forced: false)
    }

    // MARK: manual-mode mechanisms
    //
    // Apple Silicon and T2 Intel Macs expose a per-fan mode key (F{i}Md).
    // Pre-T2 Intel Macs have no such key: manual control there is the legacy
    // `FS! ` bitmask, where bit i forces fan i. Both are supported so the write
    // path degrades by inspecting the hardware rather than by assumption.

    func forcedMode(index: Int) -> Bool? {
        if let mode = readUInt8("F\(index)Md") { return mode != 0 }
        guard let mask = forceMask() else { return nil }
        return mask & (UInt16(1) << UInt16(index)) != 0
    }

    private func setForcedMode(index: Int, forced: Bool) -> Bool {
        if (try? readKey("F\(index)Md")) != nil {
            return writeUInt8("F\(index)Md", forced ? 1 : 0)
        }
        guard let mask = forceMask() else { return false }
        let bit = UInt16(1) << UInt16(index)
        let updated = forced ? (mask | bit) : (mask & ~bit)
        // FS! is big-endian, like the fixed-point types it sits beside.
        return (try? writeKey("FS! ", bytes: [UInt8(updated >> 8), UInt8(updated & 0xff)])) != nil
    }

    private func forceMask() -> UInt16? {
        guard let (_, bytes) = try? readKey("FS! "), bytes.count == 2 else { return nil }
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }
}
