//
//  SMC.swift
//  BoringNotchXPCHelper
//
//  Minimal AppleSMC client: CPU temperature, fan speeds, and fan presets.
//  Reading works unprivileged; writing fan keys needs root (see FanControl).
//

import Foundation
import IOKit

/// Mirrors the kernel's SMCKeyData_t (80 bytes). keyInfo carries explicit padding:
/// Swift packs fields after a tuple's size (9), C after its stride (12).
private struct SMCKeyData {
    typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    var key: UInt32 = 0
    var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
    var pLimit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
    var keyInfo: (dataSize: UInt32, dataType: UInt32, dataAttributes: UInt8, pad0: UInt8, pad1: UInt8, pad2: UInt8) = (0, 0, 0, 0, 0, 0)
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

final class SMC {
    private enum Command: UInt8 { case readBytes = 5, writeBytes = 6, keyAtIndex = 8, keyInfo = 9 }
    private var connection: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit { IOServiceClose(connection) }

    private static func code(_ key: String) -> UInt32 { key.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    private static func name(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? ""
    }

    private func call(_ input: SMCKeyData) -> SMCKeyData? {
        var input = input
        var output = SMCKeyData()
        var size = MemoryLayout<SMCKeyData>.stride
        let status = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCKeyData>.stride, &output, &size)
        return status == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    private func info(_ key: String) -> (size: UInt32, type: String)? {
        var input = SMCKeyData()
        input.key = Self.code(key)
        input.data8 = Command.keyInfo.rawValue
        return call(input).map { ($0.keyInfo.dataSize, Self.name($0.keyInfo.dataType)) }
    }

    func read(_ key: String) -> Double? {
        guard let info = info(key) else { return nil }
        var input = SMCKeyData()
        input.key = Self.code(key)
        input.keyInfo.dataSize = info.size
        input.data8 = Command.readBytes.rawValue
        guard let output = call(input) else { return nil }
        let b = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.size))) }
        switch info.type {
        case "flt " where b.count >= 4: return Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "ui8 " where b.count >= 1: return Double(b[0])
        case "ui16" where b.count >= 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32" where b.count >= 4: return Double(b.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case "fpe2" where b.count >= 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case "sp78" where b.count >= 2: return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        default: return nil
        }
    }

    @discardableResult
    func write(_ key: String, _ value: Double) -> Bool {
        guard let info = info(key) else { return false }
        let bytes: [UInt8]
        switch info.type {
        case "flt ": bytes = withUnsafeBytes(of: Float(value)) { Array($0) }
        case "ui8 ": bytes = [UInt8(clamping: Int(value))]
        case "fpe2": let v = UInt16(clamping: Int(value * 4)); bytes = [UInt8(v >> 8), UInt8(v & 0xFF)]
        default: return false
        }
        var input = SMCKeyData()
        input.key = Self.code(key)
        input.keyInfo.dataSize = info.size
        input.data8 = Command.writeBytes.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { buffer in
            for (i, byte) in bytes.prefix(buffer.count).enumerated() { buffer[i] = byte }
        }
        return call(input) != nil
    }

    private func key(at index: Int) -> String? {
        var input = SMCKeyData()
        input.data8 = Command.keyAtIndex.rawValue
        input.data32 = UInt32(index)
        return call(input).map { Self.name($0.key) }
    }

    // MARK: - Readings

    /// "Tp*" keys are CPU die sensors on Apple Silicon. Scanning ~3k keys is slow, so do it once.
    private static var cpuKeys: [String]?

    /// Hottest CPU sensor — the first number to move under load.
    // ponytail: max over "Tp*" keys, skipping ones stuck at exactly 40.0 (placeholders on M4 Pro that
    // would floor the reading at 40). Swap for a per-chip key list if a model reports bogus values.
    func cpuTemperature() -> Double? {
        if Self.cpuKeys == nil {
            let count = Int(read("#KEY") ?? 0)
            Self.cpuKeys = (0..<count).compactMap { key(at: $0) }.filter { $0.hasPrefix("Tp") }
        }
        return Self.cpuKeys?.compactMap { read($0) }.filter { (10...130).contains($0) && $0 != 40 }.max()
    }

    /// Internal SSD (NAND). On M4 Pro this matched the drive's own NVMe SMART temperature.
    func ssdTemperature() -> Double? {
        read("TH0x").flatMap { (10...130).contains($0) ? $0 : nil }
    }

    var fanCount: Int { Int(read("FNum") ?? 0) }

    func fanSpeeds() -> [Double] {
        (0..<fanCount).map { read("F\($0)Ac") ?? 0 }
    }
}

/// Fan presets, run as root by the installed setuid copy of this helper: `boringnotch-fan fan <preset>`.
enum FanControl {
    static let presets = ["auto", "3500", "max"]
    static let installedToolPath = "/usr/local/libexec/boringnotch-fan"

    static func apply(_ preset: String) -> Int32 {
        guard presets.contains(preset) else { return 2 }
        guard let smc = SMC() else { return 3 }
        let fans = 0..<smc.fanCount

        if preset == "auto" {
            fans.forEach { smc.write("F\($0)Md", 0) }
            smc.write("Ftst", 0)
            return 0
        }

        // Apple Silicon only accepts manual mode after "Ftst" (fan test) unlock, which takes a few seconds.
        smc.write("Ftst", 1)
        for fan in fans {
            var manual = false
            for _ in 0..<20 where !manual {
                manual = smc.write("F\(fan)Md", 1) && smc.read("F\(fan)Md") == 1
                if !manual { usleep(500_000) }
            }
            guard manual else { return 4 }
            let minRPM = smc.read("F\(fan)Mn") ?? 0
            let maxRPM = smc.read("F\(fan)Mx") ?? 0
            let target = preset == "max" ? maxRPM : min(max(3500, minRPM), maxRPM)
            guard smc.write("F\(fan)Tg", target) else { return 5 }
        }
        return 0
    }
}
