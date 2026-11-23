//
//  AwakeView.swift
//  boringNotch
//

import IOKit
import IOKit.pwr_mgt
import SwiftUI

/// Keeps the Mac awake. `.display` holds an idle-display-sleep assertion (released when the app exits);
/// `.lidClosed` also sets `pmset disablesleep 1` (root, system-wide and persistent until undone).
@MainActor
final class AwakeController: ObservableObject {
    enum Mode { case normal, display, lidClosed }

    static let shared = AwakeController()

    @Published private(set) var mode: Mode = .normal
    @Published private(set) var busy = false
    @Published var error: String?
    /// When the timer returns us to Normal; nil = until turned off.
    @Published private(set) var endsAt: Date?
    /// Minutes of the chosen preset; nil with `endsAt` set means an alarm time.
    @Published private(set) var preset: Int?
    private var assertion: IOPMAssertionID = 0
    private var timer: Task<Void, Never>?

    private init() {
        // A crash in lid-closed mode leaves `disablesleep` on; show it so "Normal" can undo it.
        if Self.sleepDisabled {
            mode = .lidClosed
            holdDisplay(true)
        }
    }

    /// `pmset -g`'s SleepDisabled, as published on the power-management root domain.
    static var sleepDisabled: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false
    }

    func set(_ newMode: Mode) async {
        guard newMode != mode, !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        if (newMode == .lidClosed) != (mode == .lidClosed),
           let message = await XPCHelperClient.shared.setSleepDisabled(newMode == .lidClosed) {
            error = message
            return
        }
        holdDisplay(newMode != .normal)
        mode = newMode
        if newMode == .normal { await schedule(nil) }
    }

    /// Stay awake (Keep Screen On if currently Normal) until `date`, then go back to Normal. nil = until turned off.
    func schedule(_ date: Date?, preset: Int? = nil) async {
        if date != nil, mode == .normal {
            await set(.display)
            guard mode != .normal else { return }
        }
        timer?.cancel()
        endsAt = date
        self.preset = preset
        guard let date else { return }
        timer = Task { [weak self] in
            // Continuous clock keeps counting while the Mac sleeps, so a late wake still ends the timer.
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)), clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.set(.normal)
        }
    }

    private func holdDisplay(_ on: Bool) {
        if on, assertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Boring Notch: keep screen on" as CFString,
                &assertion
            )
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}

struct AwakeView: View {
    @ObservedObject private var controller = AwakeController.shared
    @State private var alarm = Date.now.addingTimeInterval(3600)

    private static let presets = [10, 30, 50, 60, 120]

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                option(.normal, icon: "moon.zzz", title: "Normal", subtitle: "Sleep as usual")
                option(.display, icon: "display", title: "Keep Screen On", subtitle: "Display stays on")
                option(.lidClosed, icon: "laptopcomputer", title: "Lid Closed Too", subtitle: "Stays awake when closed")
            }
            .frame(height: 44)
            HStack(spacing: 6) {
                chip("∞", selected: controller.mode != .normal && controller.endsAt == nil) {
                    await controller.schedule(nil)
                }
                ForEach(Self.presets, id: \.self) { minutes in
                    chip(minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h", selected: controller.preset == minutes) {
                        await controller.schedule(.now.addingTimeInterval(Double(minutes) * 60), preset: minutes)
                    }
                }
                alarmChip
            }
            .frame(height: 26)
            Group {
                if let error = controller.error {
                    Text(error).foregroundStyle(.red)
                } else if let endsAt = controller.endsAt {
                    Text("Back to Normal at \(endsAt, style: .time) · \(endsAt, style: .timer) left").foregroundStyle(.gray)
                } else if controller.mode == .lidClosed {
                    Text("Won't sleep even in a bag. Switch back to Normal when done.").foregroundStyle(.orange)
                }
            }
            .font(.system(size: 10))
            .lineLimit(1)
        }
        .padding(.top, 4)
    }

    /// Wake-until time of day; the next occurrence of it (today or tomorrow).
    private var alarmChip: some View {
        let selected = controller.endsAt != nil && controller.preset == nil
        return HStack(spacing: 4) {
            Button {
                Task { await scheduleAlarm() }
            } label: {
                Image(systemName: "alarm").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            TimeField(date: $alarm)
                .fixedSize()
                .onChange(of: alarm) { Task { await scheduleAlarm() } }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(chipBackground(selected))
        .disabled(controller.busy)
    }

    private func scheduleAlarm() async {
        let time = Calendar.current.dateComponents([.hour, .minute], from: alarm)
        guard let next = Calendar.current.nextDate(after: .now, matching: time, matchingPolicy: .nextTime) else { return }
        await controller.schedule(next)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(chipBackground(selected))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(controller.busy)
    }

    private func chipBackground(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(white: selected ? 0.22 : 0.08))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(selected ? 0.5 : 0), lineWidth: 1))
    }

    private func option(_ mode: AwakeController.Mode, icon: String, title: String, subtitle: String) -> some View {
        let selected = controller.mode == mode
        return Button {
            Task { await controller.set(mode) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.gray)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: selected ? 0.22 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(selected ? 0.5 : 0), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(controller.busy)
    }
}

/// SwiftUI's field DatePicker draws its own bezel box; this is the same control without it, sized to match the chips.
private struct TimeField: NSViewRepresentable {
    @Binding var date: Date

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textField
        picker.datePickerElements = .hourMinute
        picker.isBordered = false
        picker.isBezeled = false
        picker.drawsBackground = false
        picker.font = .systemFont(ofSize: 11, weight: .medium)
        picker.textColor = .white
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.date = $date
        if picker.dateValue != date { picker.dateValue = date }
    }

    func makeCoordinator() -> Coordinator { Coordinator(date: $date) }

    final class Coordinator: NSObject {
        var date: Binding<Date>
        init(date: Binding<Date>) { self.date = date }
        @objc func changed(_ sender: NSDatePicker) { date.wrappedValue = sender.dateValue }
    }
}

#Preview {
    AwakeView()
        .frame(width: 616, height: 136)
        .padding()
        .background(.black)
        .preferredColorScheme(.dark)
}
