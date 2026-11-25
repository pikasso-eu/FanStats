import Foundation
import IOKit

// MARK: - Fehler

public enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t, String)
    case notFound(String)
    case badSize(Int)

    public var description: String {
        switch self {
        case .serviceNotFound:
            return "AppleSMC-Dienst nicht gefunden"
        case .openFailed(let kr):
            return "IOServiceOpen(AppleSMC) fehlgeschlagen: 0x\(String(kr, radix: 16))"
        case .callFailed(let kr, let cmd):
            return "SMC-Aufruf \(cmd) fehlgeschlagen: 0x\(String(kr, radix: 16))"
        case .notFound(let key):
            return "SMC-Key \(key) existiert nicht"
        case .badSize(let n):
            return "unerwartete Datengröße \(n)"
        }
    }
}

// MARK: - Wert

public struct SMCVal {
    public let key: String
    public let dataType: String
    public let bytes: [UInt8]

    /// Rohwert als Zahl. Versteht die Datentypen, die auf Intel- und
    /// Apple-Silicon-Macs vorkommen (`flt ` ist auf Apple Silicon der Standard).
    public var doubleValue: Double? {
        func be16() -> UInt16? {
            guard bytes.count >= 2 else { return nil }
            return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        }
        func be32() -> UInt32? {
            guard bytes.count >= 4 else { return nil }
            return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        }

        switch dataType {
        case "sp78":                                  // signed 8.8 fixed point (Temperaturen)
            guard bytes.count >= 2 else { return nil }
            return Double(Int8(bitPattern: bytes[0])) + Double(bytes[1]) / 256.0
        case "sp87", "spa5", "sp4b", "sp5a", "sppc", "sp69", "sp5b":
            guard let raw = be16() else { return nil }
            return Double(Int16(bitPattern: raw)) / 256.0
        case "fpe2":                                  // unsigned 14.2 fixed point (Lüfter-RPM)
            guard let raw = be16() else { return nil }
            return Double(raw) / 4.0
        case "flt ":                                  // 32-bit float, SMC speichert Little-Endian
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let f = Float(bitPattern: raw)
            return f.isFinite ? Double(f) : nil
        case "ui8 ":
            return bytes.first.map { Double($0) }
        case "ui16":
            return be16().map { Double($0) }
        case "ui32":
            return be32().map { Double($0) }
        case "si8 ":
            return bytes.first.map { Double(Int8(bitPattern: $0)) }
        case "si16":
            return be16().map { Double(Int16(bitPattern: $0)) }
        default:
            return nil
        }
    }

    public var intValue: Int? {
        doubleValue.map { Int($0.rounded()) }
    }
}

// MARK: - Verbindung

/// Zugriff auf den AppleSMC-Userclient.
///
/// Liest über `IOConnectCallStructMethod` mit einer 80-Byte-Struktur, deren Felder
/// hier über feste Offsets angesprochen werden. Das entspricht dem klassischen
/// `SMCKeyData_t` aus smcFanControl/HWSensors:
///
///     key(0) vers(4) pLimitData(10) keyInfo(28) result(40) status(41)
///     data8(42) data32(44) bytes(48)  -> 80 Byte
public final class SMC {
    public static let shared = try? SMC()

    private var conn: io_connect_t = 0
    private let structSize = 80
    /// Der Userclient ist nicht threadsicher - alle Aufrufe serialisieren.
    private let lock = NSLock()

    private static let kernelIndex: UInt32 = 2   // KERNEL_INDEX_SMC
    private static let cmdReadBytes: UInt8 = 5   // SMC_CMD_READ_BYTES
    private static let cmdReadIndex: UInt8 = 8   // SMC_CMD_READ_INDEX
    private static let cmdReadKeyInfo: UInt8 = 9 // SMC_CMD_READ_KEYINFO

    public init() throws {
        guard let matching = IOServiceMatching("AppleSMC") else {
            throw SMCError.serviceNotFound
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        var c: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &c)
        guard kr == KERN_SUCCESS else { throw SMCError.openFailed(kr) }
        conn = c
    }

    deinit {
        if conn != 0 { IOServiceClose(conn) }
    }

    // MARK: Byte-Helfer

    private func put(_ buf: inout [UInt8], _ off: Int, _ value: UInt32) {
        buf[off] = UInt8(truncatingIfNeeded: value)
        buf[off + 1] = UInt8(truncatingIfNeeded: value >> 8)
        buf[off + 2] = UInt8(truncatingIfNeeded: value >> 16)
        buf[off + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private func get(_ buf: [UInt8], _ off: Int) -> UInt32 {
        UInt32(buf[off]) | UInt32(buf[off + 1]) << 8
            | UInt32(buf[off + 2]) << 16 | UInt32(buf[off + 3]) << 24
    }

    /// "TC0P" -> 0x54433050 (Big-Endian-FourCC), wie `_strtoul(key, 4, 16)` in smc.c
    static func fourCC(_ key: String) -> UInt32? {
        let scalars = Array(key.utf8)
        guard scalars.count == 4 else { return nil }
        return UInt32(scalars[0]) << 24 | UInt32(scalars[1]) << 16
            | UInt32(scalars[2]) << 8 | UInt32(scalars[3])
    }

    static func string(from fourCC: UInt32) -> String {
        let b = [UInt8(truncatingIfNeeded: fourCC >> 24),
                 UInt8(truncatingIfNeeded: fourCC >> 16),
                 UInt8(truncatingIfNeeded: fourCC >> 8),
                 UInt8(truncatingIfNeeded: fourCC)]
        return String(bytes: b, encoding: .ascii) ?? "????"
    }

    // MARK: Aufruf

    private func call(_ input: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: structSize)
        var outSize = structSize
        lock.lock()
        defer { lock.unlock() }
        let kr: kern_return_t = input.withUnsafeBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                IOConnectCallStructMethod(conn, SMC.kernelIndex,
                                          inPtr.baseAddress, structSize,
                                          outPtr.baseAddress, &outSize)
            }
        }
        guard kr == KERN_SUCCESS else {
            throw SMCError.callFailed(kr, "cmd=\(input[42])")
        }
        return output
    }

    // MARK: Öffentliche API

    /// Anzahl der SMC-Keys (Key "#KEY").
    public var keyCount: Int {
        (try? read("#KEY"))?.intValue ?? 0
    }

    /// Key an Position `index` der internen Key-Tabelle.
    public func key(at index: Int) throws -> String {
        var buf = [UInt8](repeating: 0, count: structSize)
        buf[42] = SMC.cmdReadIndex
        put(&buf, 44, UInt32(index))
        let out = try call(buf)
        return SMC.string(from: get(out, 0))
    }

    /// Alle vorhandenen Keys (kann ein paar Millisekunden dauern).
    public func allKeys() -> [String] {
        let n = keyCount
        guard n > 0 else { return [] }
        var result: [String] = []
        result.reserveCapacity(n)
        for i in 0..<n {
            if let k = try? key(at: i) { result.append(k) }
        }
        return result
    }

    public func read(_ key: String) throws -> SMCVal {
        guard let code = SMC.fourCC(key) else { throw SMCError.notFound(key) }

        // 1) Key-Info: Datentyp und Länge
        var info = [UInt8](repeating: 0, count: structSize)
        put(&info, 0, code)
        info[42] = SMC.cmdReadKeyInfo
        let infoOut = try call(info)

        let dataSize = Int(get(infoOut, 28))
        let dataType = SMC.string(from: get(infoOut, 32))
        guard dataSize > 0, dataSize <= 32 else { throw SMCError.badSize(dataSize) }

        // 2) Bytes lesen
        var req = [UInt8](repeating: 0, count: structSize)
        put(&req, 0, code)
        put(&req, 28, UInt32(dataSize))
        req[42] = SMC.cmdReadBytes
        let out = try call(req)

        let bytes = Array(out[48..<(48 + dataSize)])
        return SMCVal(key: key, dataType: dataType, bytes: bytes)
    }

    /// Wert als Zahl, `nil` wenn der Key fehlt oder der Typ unbekannt ist.
    public func number(_ key: String) -> Double? {
        (try? read(key))?.doubleValue
    }
}
