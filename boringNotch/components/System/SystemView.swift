//
//  SystemView.swift
//  boringNotch
//

import IOKit
import Network
import SwiftUI

struct SystemView: View {
    /// Preset applied this session. The app resets fans to "auto" on quit when it isn't.
    @MainActor static var fanPreset = "auto"

    @State private var sampler = SystemSampler()
    @State private var stats = SystemSampler.Stats()
    @State private var ssd: Double?
    @State private var batteryTemp: Double?
    @State private var fans: [Double] = []
    @State private var preset = SystemView.fanPreset
    @State private var applying: String?
    @State private var error: String?

    private let presets = [("auto", "Auto"), ("3500", "3500"), ("max", "Max")]

    var body: some View {
        HStack(spacing: 6) {
            thermalCard
                .frame(width: 150)

            infoCard(icon: "cpu", title: "CPU", value: percent(stats.cpuUser + stats.cpuSystem), lines: [
                "System \(percent(stats.cpuSystem))",
                "User \(percent(stats.cpuUser))",
                "Idle \(percent(stats.cpuIdle))",
            ])

            infoCard(icon: "internaldrive", title: "Storage", value: percent(stats.storageUsedFraction * 100), lines: [
                "\(bytes(stats.storageUsed)) / \(bytes(stats.storageTotal))",
            ]) {
                ProgressView(value: stats.storageUsedFraction)
                    .progressViewStyle(.linear)
                    .tint(.blue)
            }

            infoCard(icon: "battery.75percent", title: "Battery", value: stats.batteryLevel.map { "\($0)%" } ?? "--", lines: [
                stats.onACPower ? "AC Power" : "Battery",
                "Health \(stats.batteryHealth.map { percent($0) } ?? "--")",
                "Cycles \(stats.batteryCycles.map(String.init) ?? "--")",
                "Temp \(celsius(batteryTemp))",
            ])

            infoCard(icon: "network", title: stats.networkName, value: nil, lines: [
                stats.localIP ?? "No IP",
                "↑ \(bytes(stats.uploadPerSecond))/s",
                "↓ \(bytes(stats.downloadPerSecond))/s",
            ])
        }
        .padding(.top, 4)
        .task {
            while !Task.isCancelled {
                stats = sampler.sample()
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
        VStack(spacing: 6) {
            VStack(spacing: 0) {
                Text("SSD")
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
                Text(celsius(ssd))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(ssdColor)
            }

            Text(fans.isEmpty ? "No fans" : fans.map { "\(Int($0))" }.joined(separator: " · ") + " RPM")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.gray)

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
        .padding(8)
        .frame(maxHeight: .infinity)
        .background(card)
    }

    private func infoCard(
        icon: String, title: String, value: String?, lines: [String],
        @ViewBuilder footer: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(.gray)

            if let value {
                Text(value)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }

            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            footer()
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(card)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08))
    }

    // MARK: - Formatting

    private func percent(_ value: Double) -> String { String(format: "%.1f%%", value) }
    private func celsius(_ value: Double?) -> String { value.map { String(format: "%.1f°C", $0) } ?? "--" }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

    private var ssdColor: Color {
        // SSDs typically start throttling around 70°C.
        guard let ssd else { return .white }
        return ssd < 60 ? .white : ssd < 70 ? .orange : .red
    }

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

// MARK: - Sampling

/// Reads CPU / storage / battery / network stats. CPU and network values are deltas since the last sample.
final class SystemSampler {
    struct Stats {
        var cpuUser = 0.0, cpuSystem = 0.0, cpuIdle = 0.0
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
        .frame(width: 616, height: 136)
        .padding()
        .background(.black)
        .preferredColorScheme(.dark)
}
