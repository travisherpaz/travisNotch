//
//  SystemView.swift
//  boringNotch
//

import Charts
import IOKit
import Network
import SwiftUI

struct SystemView: View {
    /// Preset applied this session. The app resets fans to "auto" on quit when it isn't.
    @MainActor static var fanPreset = "auto"
    private static let historyLength = 30 // 2s samples: one minute

    @State private var sampler = SystemSampler()
    @State private var stats = SystemSampler.Stats()
    @State private var cpuHistory: [Double] = []
    @State private var downloadHistory: [Double] = []
    @State private var uploadHistory: [Double] = []
    @State private var ssd: Double?
    @State private var batteryTemp: Double?
    @State private var fans: [Double] = []
    @State private var preset = SystemView.fanPreset
    @State private var applying: String?
    @State private var error: String?

    private let presets = [("auto", "Auto"), ("3500", "3500"), ("max", "Max")]

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                thermalCard
                cpuCard
                memoryCard
            }
            GridRow {
                storageCard
                batteryCard
                networkCard
            }
        }
        .padding(.top, 4)
        .task {
            while !Task.isCancelled {
                stats = sampler.sample()
                append(stats.cpuUser + stats.cpuSystem, to: &cpuHistory)
                append(Double(stats.downloadPerSecond), to: &downloadHistory)
                append(Double(stats.uploadPerSecond), to: &uploadHistory)
                let thermal = await XPCHelperClient.shared.systemStats()
                ssd = thermal.ssd
                batteryTemp = thermal.battery
                fans = thermal.fans
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - Cards

    private var thermalCard: some View {
        card("thermometer.medium", "Thermal") {
            gaugeRow(
                fraction: (ssd ?? 0) / 80, label: ssd.map { String(format: "%.1f°", $0) } ?? "--",
                caption: "SSD", color: severity(ssd ?? 0, warn: 60, critical: 70), // SSDs throttle around 70°C
                details: fans.indices.map { ("Fan \($0 + 1)", "\(Int(fans[$0])) rpm") }
            )
            HStack(spacing: 4) {
                ForEach(presets, id: \.0) { id, title in
                    Button {
                        Task { await apply(id) }
                    } label: {
                        Text(applying == id ? "…" : title)
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(preset == id ? 0.25 : 0.08)))
                    }
                    .buttonStyle(.plain)
                    .disabled(applying != nil)
                }
            }
            if let error {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private var cpuCard: some View {
        let usage = stats.cpuUser + stats.cpuSystem
        return card("cpu", "CPU") {
            gaugeRow(
                fraction: usage / 100, label: percent(usage), caption: "used",
                color: severity(usage, warn: 80, critical: 95), // short spikes are normal
                details: [("System", percent(stats.cpuSystem)), ("User", percent(stats.cpuUser)), ("Idle", percent(stats.cpuIdle))]
            )
            Sparkline(series: [(cpuHistory, .green)], length: Self.historyLength, maxValue: 100)
        }
    }

    private var memoryCard: some View {
        card("memorychip", "Memory") {
            gaugeRow(
                fraction: stats.memoryUsedFraction, label: percent(stats.memoryUsedFraction * 100), caption: "used",
                // macOS keeps RAM full on purpose; color by the kernel's own pressure level instead of usage.
                color: stats.memoryPressureLevel >= 4 ? .red : stats.memoryPressureLevel >= 2 ? .orange : .green,
                details: [
                    ("Pressure", stats.memoryPressure.isNaN ? "--" : percent(stats.memoryPressure)),
                    ("App", bytes(stats.memoryApp)),
                    ("Wired", bytes(stats.memoryWired)),
                    ("Compr.", bytes(stats.memoryCompressed)),
                ]
            )
        }
    }

    private var storageCard: some View {
        card("internaldrive", "Storage") {
            gaugeRow(
                fraction: stats.storageUsedFraction, label: percent(stats.storageUsedFraction * 100), caption: "used",
                color: severity(stats.storageUsedFraction * 100, warn: 85, critical: 95),
                details: [
                    ("Used", bytes(stats.storageUsed)),
                    ("Free", bytes(stats.storageTotal - stats.storageUsed)),
                    ("Total", bytes(stats.storageTotal)),
                ]
            )
        }
    }

    private var batteryCard: some View {
        let level = Double(stats.batteryLevel ?? 0)
        return card(stats.onACPower ? "battery.100percent.bolt" : "battery.75percent", "Battery") {
            gaugeRow(
                fraction: level / 100, label: stats.batteryLevel.map { "\($0)%" } ?? "--",
                caption: stats.onACPower ? "AC" : "battery",
                // macOS low-battery warnings fire at 20% and 10%; on AC there's nothing to act on.
                color: stats.onACPower ? .green : severity(100 - level, warn: 80, critical: 90),
                details: [
                    ("Health", stats.batteryHealth.map { percent($0) } ?? "--"),
                    ("Cycles", stats.batteryCycles.map(String.init) ?? "--"),
                    ("Temp", batteryTemp.map { String(format: "%.1f°C", $0) } ?? "--"),
                ]
            )
        }
    }

    private var networkCard: some View {
        card("network", stats.networkName) {
            VStack(alignment: .leading, spacing: 2) {
                detail("IP", stats.localIP ?? "--")
                detail("↓ Down", "\(bytes(stats.downloadPerSecond))/s", color: .cyan)
                detail("↑ Up", "\(bytes(stats.uploadPerSecond))/s", color: .pink)
            }
            Sparkline(series: [(downloadHistory, .cyan), (uploadHistory, .pink)], length: Self.historyLength, maxValue: nil)
        }
    }

    // MARK: - Building blocks

    private func card<Content: View>(_ icon: String, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.gray)
                .lineLimit(1)
            content()
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
    }

    private func gaugeRow(fraction: Double, label: String, caption: String, color: Color, details: [(String, String)]) -> some View {
        HStack(spacing: 10) {
            RingGauge(fraction: fraction, label: label, caption: caption, color: color)
                .frame(width: 62, height: 62)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(details, id: \.0) { detail($0.0, $0.1) }
            }
        }
    }

    private func detail(_ name: String, _ value: String, color: Color = .gray) -> some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(color)
            Spacer(minLength: 4)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 10))
        .lineLimit(1)
    }

    // MARK: - Helpers

    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }

    /// Per-metric thresholds: each card passes the levels that actually matter for it.
    private func severity(_ value: Double, warn: Double, critical: Double) -> Color {
        value >= critical ? .red : value >= warn ? .orange : .green
    }

    private func percent(_ value: Double) -> String { String(format: "%.1f%%", value) }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

    private func apply(_ id: String) async {
        applying = id
        error = nil
        if let message = await XPCHelperClient.shared.setFanPreset(id) {
            error = message
        } else {
            preset = id
            Self.fanPreset = id
        }
        applying = nil
    }
}

/// Netdata-style ring: grey track, colored arc, value in the middle.
private struct RingGauge: View {
    let fraction: Double
    let label: String
    let caption: String
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: 6)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: fraction)
            VStack(spacing: 0) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                Text(caption)
                    .font(.system(size: 8))
                    .foregroundStyle(.gray)
            }
            .padding(8)
        }
    }
}

/// Filled line chart over the last `length` samples; several series share one y scale.
private struct Sparkline: View {
    let series: [([Double], Color)]
    let length: Int
    let maxValue: Double?

    var body: some View {
        let top = maxValue ?? max(series.flatMap(\.0).max() ?? 1, 1)
        Chart {
            ForEach(series.indices, id: \.self) { s in
                let (values, color) = series[s]
                ForEach(values.indices, id: \.self) { i in
                    AreaMark(x: .value("t", i), y: .value("v", values[i]), series: .value("s", s))
                        .foregroundStyle(color.opacity(0.25))
                    LineMark(x: .value("t", i), y: .value("v", values[i]), series: .value("s", s))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXScale(domain: 0...(length - 1))
        .chartYScale(domain: 0...top)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Sampling

/// Reads CPU / memory / storage / battery / network stats. CPU and network values are deltas since the last sample.
final class SystemSampler {
    struct Stats {
        var cpuUser = 0.0, cpuSystem = 0.0, cpuIdle = 0.0
        var memoryApp: Int64 = 0, memoryWired: Int64 = 0, memoryCompressed: Int64 = 0, memoryTotal: Int64 = 0
        var memoryPressure = Double.nan
        /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical (Activity Monitor's colors).
        var memoryPressureLevel = 1
        var memoryUsedFraction: Double {
            memoryTotal > 0 ? Double(memoryApp + memoryWired + memoryCompressed) / Double(memoryTotal) : 0
        }
        var storageUsed: Int64 = 0, storageTotal: Int64 = 0
        var storageUsedFraction: Double { storageTotal > 0 ? Double(storageUsed) / Double(storageTotal) : 0 }
        var batteryLevel: Int?, batteryHealth: Double?, batteryCycles: Int?
        var onACPower = false
        var networkName = "Network"
        var localIP: String?
        var uploadPerSecond: Int64 = 0, downloadPerSecond: Int64 = 0
    }

    private var lastCPUTicks: [UInt32]?
    private var lastNetwork: (bytesIn: UInt64, bytesOut: UInt64, time: Date)?
    private let pathMonitor = NWPathMonitor()
    private var path: NWPath?

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] in self?.path = $0 }
        pathMonitor.start(queue: .main)
    }

    deinit { pathMonitor.cancel() }

    func sample() -> Stats {
        var stats = Stats()
        sampleCPU(into: &stats)
        sampleMemory(into: &stats)
        sampleStorage(into: &stats)
        sampleBattery(into: &stats)
        sampleNetwork(into: &stats)
        return stats
    }

    private func sampleCPU(into stats: inout Stats) {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        // user, system, idle, nice
        let ticks = [load.cpu_ticks.0, load.cpu_ticks.1, load.cpu_ticks.2, load.cpu_ticks.3]
        defer { lastCPUTicks = ticks }
        guard let last = lastCPUTicks else { return }
        let delta = zip(ticks, last).map { Double($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return }
        stats.cpuUser = (delta[0] + delta[3]) / total * 100
        stats.cpuSystem = delta[1] / total * 100
        stats.cpuIdle = delta[2] / total * 100
    }

    /// Same breakdown as Activity Monitor: used = app + wired + compressed.
    private func sampleMemory(into stats: inout Stats) {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let page = Int64(vm_kernel_page_size)
        stats.memoryApp = max(Int64(info.internal_page_count) - Int64(info.purgeable_count), 0) * page
        stats.memoryWired = Int64(info.wire_count) * page
        stats.memoryCompressed = Int64(info.compressor_page_count) * page
        stats.memoryTotal = Int64(ProcessInfo.processInfo.physicalMemory)

        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 {
            stats.memoryPressure = Double(100 - level)
        }
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            stats.memoryPressureLevel = Int(level)
        }
    }

    private func sampleStorage(into stats: inout Stats) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return }
        stats.storageTotal = Int64(total)
        stats.storageUsed = Int64(total) - available
    }

    private func sampleBattery(into stats: inout Stats) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let battery = properties?.takeRetainedValue() as? [String: Any] else { return }
        stats.batteryLevel = battery["CurrentCapacity"] as? Int
        stats.batteryCycles = battery["CycleCount"] as? Int
        stats.onACPower = battery["ExternalConnected"] as? Bool ?? false
        // Newer macOS moves the raw capacities into "BatteryData".
        let data = battery["BatteryData"] as? [String: Any] ?? battery
        if let raw = data["AppleRawMaxCapacity"] as? Double, let design = data["DesignCapacity"] as? Double, design > 0 {
            stats.batteryHealth = raw / design * 100
        }
    }

    private func sampleNetwork(into stats: inout Stats) {
        let interface = path?.availableInterfaces.first
        if let interface {
            switch interface.type {
            case .wifi: stats.networkName = "Wi-Fi"
            case .wiredEthernet: stats.networkName = "Ethernet"
            case .cellular: stats.networkName = "Cellular"
            default: stats.networkName = interface.name
            }
        }

        var bytesIn: UInt64 = 0, bytesOut: UInt64 = 0
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return }
        defer { freeifaddrs(addresses) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let name = String(cString: entry.ifa_name)
            guard name == interface?.name, let address = entry.ifa_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    stats.localIP = String(cString: host)
                }
            case AF_LINK:
                // ponytail: 32-bit if_data counters wrap at 4 GB; a wrapped sample just reads 0 for one tick.
                if let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                    bytesIn += UInt64(data.ifi_ibytes)
                    bytesOut += UInt64(data.ifi_obytes)
                }
            default:
                break
            }
        }

        let now = Date()
        defer { lastNetwork = (bytesIn, bytesOut, now) }
        guard let last = lastNetwork, bytesIn >= last.bytesIn, bytesOut >= last.bytesOut else { return }
        let seconds = max(now.timeIntervalSince(last.time), 0.1)
        stats.downloadPerSecond = Int64(Double(bytesIn - last.bytesIn) / seconds)
        stats.uploadPerSecond = Int64(Double(bytesOut - last.bytesOut) / seconds)
    }
}

#Preview {
    SystemView()
        .frame(width: 616, height: 306)
        .padding()
        .background(.black)
        .preferredColorScheme(.dark)
}
