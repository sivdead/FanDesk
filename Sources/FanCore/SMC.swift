import Foundation
import IOKit

/// Low-level access to the Apple System Management Controller.
///
/// Wire format notes, all verified empirically on Mac17,7 (M5 Max, macOS 26.5):
///  - The request/response struct is 80 bytes; its integer fields are *native*
///    little-endian. (Marshalling them big-endian makes every call fail.)
///  - SMC data payloads, by contrast, are big-endian for the integer types but
///    **little-endian for `flt `**.
///  - Writes require root. Reads do not.
public final class SMC {

    public enum SMCError: Error, CustomStringConvertible {
        case serviceNotFound
        case openFailed(kern_return_t)
        case keyNotFound(String)
        case callFailed(key: String, rc: kern_return_t, smcResult: UInt8)
        case sizeMismatch(key: String, expected: Int, got: Int)
        case typeMismatch(key: String, expected: String, got: String)

        public var description: String {
            switch self {
            case .serviceNotFound:
                return "AppleSMC IOKit service not found"
            case .openFailed(let rc):
                return "IOServiceOpen failed (rc=0x\(String(rc, radix: 16)))"
            case .keyNotFound(let k):
                return "SMC key '\(k)' not present"
            case .callFailed(let k, let rc, let res):
                return "SMC call for '\(k)' failed (rc=0x\(String(rc, radix: 16)), result=\(res))"
            case .sizeMismatch(let k, let e, let g):
                return "SMC key '\(k)' expects \(e) bytes, got \(g)"
            case .typeMismatch(let k, let e, let g):
                return "SMC key '\(k)' is type '\(g)', expected '\(e)'"
            }
        }
    }

    public struct KeyInfo: Sendable {
        public let size: Int
        public let type: String
    }

    // MARK: - Wire layout

    private static let structSize = 80
    private enum Offset {
        static let key = 0
        static let dataSize = 28
        static let dataType = 32
        static let result = 40
        static let data8 = 42
        static let data32 = 44
        static let bytes = 48
    }
    private enum Command {
        static let readBytes: UInt8 = 5
        static let writeBytes: UInt8 = 6
        static let readIndex: UInt8 = 8
        static let readKeyInfo: UInt8 = 9
    }
    /// kSMCHandleYPCEvent
    private static let selector: UInt32 = 2

    // MARK: - State

    private var connection: io_connect_t = 0
    private let lock = NSLock()
    private var keyInfoCache: [String: KeyInfo] = [:]

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        let rc = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard rc == kIOReturnSuccess else { throw SMCError.openFailed(rc) }
        connection = conn
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    // MARK: - Byte helpers

    private static func fourCC(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for b in s.utf8.prefix(4) { v = (v << 8) | UInt32(b) }
        return v
    }

    private static func fourCCString(_ v: UInt32) -> String {
        let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                     UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    /// Struct fields are native little-endian.
    private static func putLE32(_ buf: inout [UInt8], _ off: Int, _ v: UInt32) {
        buf[off]     = UInt8(v & 0xff)
        buf[off + 1] = UInt8((v >> 8) & 0xff)
        buf[off + 2] = UInt8((v >> 16) & 0xff)
        buf[off + 3] = UInt8((v >> 24) & 0xff)
    }

    private static func getLE32(_ buf: [UInt8], _ off: Int) -> UInt32 {
        UInt32(buf[off]) | (UInt32(buf[off + 1]) << 8)
            | (UInt32(buf[off + 2]) << 16) | (UInt32(buf[off + 3]) << 24)
    }

    // MARK: - Raw call

    private func rawCall(_ input: [UInt8], key: String) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: Self.structSize)
        var outputSize = Self.structSize

        let rc = input.withUnsafeBytes { inPtr -> kern_return_t in
            output.withUnsafeMutableBytes { outPtr in
                IOConnectCallStructMethod(connection, Self.selector,
                                          inPtr.baseAddress!, Self.structSize,
                                          outPtr.baseAddress!, &outputSize)
            }
        }

        let smcResult = output[Offset.result]
        guard rc == kIOReturnSuccess, smcResult == 0, outputSize == Self.structSize else {
            throw SMCError.callFailed(key: key, rc: rc, smcResult: smcResult)
        }
        return output
    }

    // MARK: - Key metadata

    public func keyInfo(_ key: String) throws -> KeyInfo {
        lock.lock()
        if let cached = keyInfoCache[key] { lock.unlock(); return cached }
        lock.unlock()

        var input = [UInt8](repeating: 0, count: Self.structSize)
        Self.putLE32(&input, Offset.key, Self.fourCC(key))
        input[Offset.data8] = Command.readKeyInfo

        let out: [UInt8]
        do {
            out = try rawCall(input, key: key)
        } catch {
            throw SMCError.keyNotFound(key)
        }

        let info = KeyInfo(size: Int(Self.getLE32(out, Offset.dataSize)),
                           type: Self.fourCCString(Self.getLE32(out, Offset.dataType)))
        guard (1...32).contains(info.size) else {
            throw SMCError.sizeMismatch(key: key, expected: 32, got: info.size)
        }
        lock.lock(); keyInfoCache[key] = info; lock.unlock()
        return info
    }

    public func keyExists(_ key: String) -> Bool {
        (try? keyInfo(key)) != nil
    }

    /// Every key the SMC advertises. ~3700 on M-series.
    public func allKeys() throws -> [String] {
        let countBytes = try readBytes("#KEY")
        guard countBytes.count >= 4 else { return [] }
        let total = Int(UInt32(countBytes[0]) << 24 | UInt32(countBytes[1]) << 16
                        | UInt32(countBytes[2]) << 8 | UInt32(countBytes[3]))

        var keys: [String] = []
        keys.reserveCapacity(total)
        for index in 0..<total {
            var input = [UInt8](repeating: 0, count: Self.structSize)
            input[Offset.data8] = Command.readIndex
            Self.putLE32(&input, Offset.data32, UInt32(index))
            guard let out = try? rawCall(input, key: "#KEY[\(index)]") else { continue }
            keys.append(Self.fourCCString(Self.getLE32(out, Offset.key)))
        }
        return keys
    }

    // MARK: - Raw payload I/O

    public func readBytes(_ key: String) throws -> [UInt8] {
        let info = try keyInfo(key)
        var input = [UInt8](repeating: 0, count: Self.structSize)
        Self.putLE32(&input, Offset.key, Self.fourCC(key))
        Self.putLE32(&input, Offset.dataSize, UInt32(info.size))
        input[Offset.data8] = Command.readBytes

        let out = try rawCall(input, key: key)
        return Array(out[Offset.bytes..<(Offset.bytes + min(info.size, 32))])
    }

    public func writeBytes(_ key: String, _ payload: [UInt8]) throws {
        let info = try keyInfo(key)
        guard info.size == payload.count else {
            throw SMCError.sizeMismatch(key: key, expected: info.size, got: payload.count)
        }
        var input = [UInt8](repeating: 0, count: Self.structSize)
        Self.putLE32(&input, Offset.key, Self.fourCC(key))
        Self.putLE32(&input, Offset.dataSize, UInt32(info.size))
        input[Offset.data8] = Command.writeBytes
        for (i, b) in payload.enumerated() { input[Offset.bytes + i] = b }

        _ = try rawCall(input, key: key)
    }

    // MARK: - Typed accessors

    public func writeFloat(_ key: String, _ value: Float) throws {
        let bits = value.bitPattern
        try writeBytes(key, [UInt8(bits & 0xff),
                             UInt8((bits >> 8) & 0xff),
                             UInt8((bits >> 16) & 0xff),
                             UInt8((bits >> 24) & 0xff)])
    }

    public func readUInt8(_ key: String) throws -> UInt8 {
        let b = try readBytes(key)
        guard let first = b.first else { throw SMCError.sizeMismatch(key: key, expected: 1, got: 0) }
        return first
    }

    public func writeUInt8(_ key: String, _ value: UInt8) throws {
        try writeBytes(key, [value])
    }

    // MARK: - Type-agnostic numbers
    //
    // The same key is not the same type on every Mac. Fan RPM is `flt ` on this
    // hardware and `fpe2` — 14 integer bits then 2 fractional, big-endian — on
    // Intel and older Apple Silicon. Reading one through a `flt `-only accessor
    // throws `typeMismatch` on a machine whose fans are working perfectly well,
    // so ask the key what it is instead of assuming.

    /// Type names are four-character codes, so the short ones carry trailing
    /// spaces: `ui8 ` and `flt `, but `fpe2` and `ui16`. Matching the padded
    /// form is a bug waiting for whichever type you forgot to pad.
    private static func typeName(_ type: String) -> String {
        type.trimmingCharacters(in: .whitespaces)
    }

    /// Reads any of the numeric SMC encodings as a `Double`.
    public func readNumber(_ key: String) throws -> Double {
        let info = try keyInfo(key)
        let b = try readBytes(key)

        func need(_ n: Int) throws {
            guard b.count >= n else {
                throw SMCError.sizeMismatch(key: key, expected: n, got: b.count)
            }
        }

        switch Self.typeName(info.type) {
        case "flt":
            try need(4)
            let bits = UInt32(b[3]) << 24 | UInt32(b[2]) << 16 | UInt32(b[1]) << 8 | UInt32(b[0])
            return Double(Float(bitPattern: bits))
        case "fpe2":
            try need(2)
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case "ioft":
            try need(8)
            let raw = b.prefix(8).enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
            return Double(raw) / 65536.0
        case "sp78":
            try need(2)
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256.0
        case "ui8":
            try need(1)
            return Double(b[0])
        case "ui16":
            try need(2)
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32":
            try need(4)
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        default:
            throw SMCError.typeMismatch(key: key, expected: "a numeric type", got: info.type)
        }
    }

    /// Writes a `Double` back in whichever encoding the key declares.
    public func writeNumber(_ key: String, _ value: Double) throws {
        let info = try keyInfo(key)

        func be16(_ scaled: Double) -> [UInt8] {
            let raw = UInt16(max(0, min(Double(UInt16.max), scaled.rounded())))
            return [UInt8(raw >> 8), UInt8(raw & 0xff)]
        }

        switch Self.typeName(info.type) {
        case "flt":   try writeFloat(key, Float(value))
        case "fpe2":  try writeBytes(key, be16(value * 4))
        case "ui16":  try writeBytes(key, be16(value))
        case "ui8":   try writeUInt8(key, UInt8(max(0, min(255, value.rounded()))))
        default:
            throw SMCError.typeMismatch(key: key, expected: "a writable numeric type",
                                        got: info.type)
        }
    }
}
