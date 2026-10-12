import CPulso
import Foundation

public struct SMCValue: Sendable, Equatable {
    public var key: String
    /// Four-character type code, e.g. `flt ` or `ui8 `.
    public var type: String
    public var bytes: [UInt8]

    public init(key: String, type: String, bytes: [UInt8]) {
        self.key = key
        self.type = type
        self.bytes = bytes
    }

    /// Numeric interpretation of the raw bytes, or nil for types that are not numbers.
    /// Integers and fixed-point values are big-endian; `flt ` and `ioft` are little-endian.
    public var doubleValue: Double? {
        func bigEndian(_ count: Int) -> UInt64? {
            guard bytes.count >= count else { return nil }
            return bytes.prefix(count).reduce(0) { $0 << 8 | UInt64($1) }
        }
        func littleEndian(_ count: Int) -> UInt64? {
            guard bytes.count >= count else { return nil }
            return bytes.prefix(count).reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }
        // Spell the conversions out: a bare `Double.init` applied to a UInt64 resolves
        // to `Double(bitPattern:)`, which reinterprets the bits instead of converting.
        switch type {
        case "flt ":
            return littleEndian(4).map { Double(Float(bitPattern: UInt32($0))) }
        case "ui8 ", "flag":
            return bigEndian(1).map { Double($0) }
        case "ui16":
            return bigEndian(2).map { Double($0) }
        case "ui32":
            return bigEndian(4).map { Double($0) }
        case "si8 ":
            return bigEndian(1).map { Double(Int8(truncatingIfNeeded: $0)) }
        case "si16":
            return bigEndian(2).map { Double(Int16(truncatingIfNeeded: $0)) }
        case "si32":
            return bigEndian(4).map { Double(Int32(truncatingIfNeeded: $0)) }
        case "sp78":
            return bigEndian(2).map { Double(Int16(truncatingIfNeeded: $0)) / 256 }
        case "fpe2":
            return bigEndian(2).map { Double($0) / 4 }
        case "ioft":
            return littleEndian(8).map { Double($0) / 65_536 }
        default:
            return nil
        }
    }
}

enum FourCC {
    static func encode(_ text: String) -> UInt32? {
        let scalars = Array(text.utf8)
        guard scalars.count == 4 else { return nil }
        return scalars.reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func decode(_ code: UInt32) -> String {
        let bytes = [UInt8(code >> 24 & 0xFF), UInt8(code >> 16 & 0xFF), UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// A connection to the System Management Controller. Not thread-safe.
public final class SMCConnection {
    private let connection: UInt32
    private var keyInfo: [UInt32: (type: UInt32, size: UInt32)] = [:]
    private var missing: Set<UInt32> = []

    /// Fails when AppleSMC is unavailable (e.g. inside a virtual machine).
    public init?() {
        var connection: UInt32 = 0
        guard PulsoSMCOpen(&connection) == KERN_SUCCESS else { return nil }
        self.connection = connection
    }

    deinit {
        PulsoSMCClose(connection)
    }

    public func read(_ key: String) -> SMCValue? {
        guard let code = FourCC.encode(key), !missing.contains(code) else { return nil }
        let info: (type: UInt32, size: UInt32)
        if let cached = keyInfo[code] {
            info = cached
        } else {
            var type: UInt32 = 0, size: UInt32 = 0
            guard PulsoSMCReadKeyInfo(connection, code, &type, &size) == KERN_SUCCESS, size > 0, size <= 32 else {
                // Which keys exist is fixed per machine, so never ask again.
                missing.insert(code)
                return nil
            }
            info = (type, size)
            keyInfo[code] = info
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard PulsoSMCReadBytes(connection, code, info.size, &bytes) == KERN_SUCCESS else { return nil }
        return SMCValue(key: key, type: FourCC.decode(info.type), bytes: Array(bytes.prefix(Int(info.size))))
    }

    /// Writes a key's raw value and returns the kernel's result code. `bytes` must be
    /// exactly the key's size. Only root may write; anyone else gets `kIOReturnNotPrivileged`.
    public func write(_ key: String, bytes: [UInt8]) -> kern_return_t {
        guard let code = FourCC.encode(key), let current = read(key), current.bytes.count == bytes.count else {
            return kIOReturnBadArgument
        }
        return PulsoSMCWriteBytes(connection, code, UInt32(bytes.count), bytes)
    }

    /// Every key the controller exposes. Slow (one call per key): meant for diagnostics.
    public func allKeys() -> [String] {
        guard let count = read("#KEY")?.doubleValue else { return [] }
        return (0..<UInt32(count)).compactMap { index in
            var key: UInt32 = 0
            guard PulsoSMCKeyAtIndex(connection, index, &key) == KERN_SUCCESS else { return nil }
            return FourCC.decode(key)
        }
    }
}
