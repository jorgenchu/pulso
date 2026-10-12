import Darwin

enum Sysctl {
    /// Reads a fixed-size value, e.g. a struct such as `xsw_usage` or `timeval`.
    static func value<T>(_ name: String, as type: T.Type) -> T? {
        var size = MemoryLayout<T>.size
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard sysctlbyname(name, pointer, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return pointer.pointee
    }

    /// Reads an integer regardless of whether the kernel stores it in 4 or 8 bytes.
    static func int(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 4: return value(name, as: Int32.self).map { Int($0) }
        case 8: return value(name, as: Int64.self).map { Int($0) }
        default: return nil
        }
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

enum Mach {
    /// `mach_host_self()` hands out a new send right on every call, so take it once.
    static let host: mach_port_t = mach_host_self()
}
