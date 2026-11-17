//
//  SystemView.swift
//  boringNotch
//

import SwiftUI

struct SystemView: View {
    /// Preset applied this session. The app resets fans to "auto" on quit when it isn't.
    @MainActor static var fanPreset = "auto"

    @State private var cpu: Double?
    @State private var fans: [Double] = []
    @State private var preset = SystemView.fanPreset
    @State private var applying: String?
    @State private var error: String?

    private let presets = [("auto", "Auto"), ("3500", "3500"), ("max", "Max")]

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 2) {
                Text("CPU")
                    .font(.system(size: 12))
                    .foregroundStyle(.gray)
                Text(cpu.map { String(format: "%.0f°C", $0) } ?? "--")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(temperatureColor)
            }
            .frame(width: 180)
            .frame(maxHeight: .infinity)
            .background(card)

            VStack(spacing: 10) {
                HStack(spacing: 20) {
                    ForEach(fans.indices, id: \.self) { index in
                        VStack(spacing: 2) {
                            Text("Fan \(index + 1)")
                                .font(.system(size: 12))
                                .foregroundStyle(.gray)
                            Text("\(Int(fans[index])) RPM")
                                .font(.system(size: 16, weight: .medium))
                                .monospacedDigit()
                        }
                    }
                }

                HStack(spacing: 6) {
                    ForEach(presets, id: \.0) { id, title in
                        Button {
                            Task { await apply(id) }
                        } label: {
                            Text(applying == id ? "…" : title)
                                .font(.system(size: 13, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.white.opacity(preset == id ? 0.25 : 0.08)))
                        }
                        .buttonStyle(.plain)
                        .disabled(applying != nil)
                    }
                }

                if let error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(card)
        }
        .padding(.top, 4)
        .task {
            while !Task.isCancelled {
                let stats = await XPCHelperClient.shared.systemStats()
                cpu = stats.cpu
                fans = stats.fans
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08))
    }

    private var temperatureColor: Color {
        guard let cpu else { return .white }
        return cpu < 70 ? .white : cpu < 90 ? .orange : .red
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

#Preview {
    SystemView()
        .frame(width: 600, height: 140)
        .padding()
        .background(.black)
        .preferredColorScheme(.dark)
}
