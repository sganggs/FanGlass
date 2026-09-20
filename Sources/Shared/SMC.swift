// SMC.swift — shared low-level SMC access (Apple Silicon layout, little-endian fields).
// Verified on Mac16,10 (M4, macOS 26):
//   key@0 (LE FourCharCode) · dataSize@28 (LE) · dataType@32 (LE) · dataAttributes@36
//   result@40 · status@41 · command data8@42 · data32@44 (LE) · value bytes@48..80
// Commands: 5=read, 6=write, 8=key-at-index, 9=key-info. Reads need no privileges, writes need root.
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
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

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

    public func readFloat(_ key: String) -> Double? {
        guard let (type, bytes) = try? readKey(key) else { return nil }
        switch type {
        case "flt " where bytes.count == 4:
            // UInt8 buffers are 1-byte aligned; load Float via bitPattern.
            let bits = UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "sp78" where bytes.count == 2:
            return Double(Int16(bytes[1]) << 8 | Int16(bytes[0])) / 256.0
        case "fpe2" where bytes.count == 2:
            return Double(UInt16(bytes[1]) << 8 | UInt16(bytes[0])) / 4.0
        case "ui8 " where bytes.count == 1:
            return Double(bytes[0])
        case "ui16" where bytes.count == 2:
            return Double(UInt16(bytes[1]) << 8 | UInt16(bytes[0]))
        default:
            return nil
        }
    }

    public func readUInt8(_ key: String) -> UInt8? {
        guard let (_, bytes) = try? readKey(key), let first = bytes.first else { return nil }
        return first
    }

    public func writeFloat(_ key: String, _ value: Float) -> Bool {
        var v = value
        let bytes = withUnsafeBytes(of: &v) { Array($0) }
        return (try? writeKey(key, bytes: bytes)) != nil
    }

    public func writeUInt8(_ key: String, _ value: UInt8) -> Bool {
        (try? writeKey(key, bytes: [value])) != nil
    }
}

// MARK: - Fan model (Apple Silicon keys)

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
        let forced = (readUInt8("F\(index)Md") ?? 0) != 0
        return FanStatus(index: index, actualRPM: actual, minRPM: minR, maxRPM: maxR, forced: forced)
    }

    /// Force a target RPM (root only). Values are clamped to the fan's hardware range.
    func setFanForced(index: Int, rpm: Double) -> Bool {
        guard let minR = readFloat("F\(index)Mn"), let maxR = readFloat("F\(index)Mx") else { return false }
        let target = Float(min(max(rpm, minR), maxR))
        return writeUInt8("F\(index)Md", 1) && writeFloat("F\(index)Tg", target)
    }

    /// Return a fan to system automatic control (root only).
    func setFanAuto(index: Int) -> Bool {
        writeUInt8("F\(index)Md", 0)
    }
}
