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
    private var assertion: IOPMAssertionID = 0

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

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                option(.normal, icon: "moon.zzz", title: "Normal", subtitle: "Sleep as usual")
                option(.display, icon: "display", title: "Keep Screen On", subtitle: "Until you turn it off")
                option(.lidClosed, icon: "laptopcomputer", title: "Lid Closed Too", subtitle: "Stays awake when closed")
            }
            Group {
                if let error = controller.error {
                    Text(error).foregroundStyle(.red)
                } else if controller.mode == .lidClosed {
                    Text("Won't sleep even in a bag. Switch back to Normal when done.").foregroundStyle(.orange)
                }
            }
            .font(.system(size: 10))
            .lineLimit(1)
        }
        .padding(.top, 4)
    }

    private func option(_ mode: AwakeController.Mode, icon: String, title: String, subtitle: String) -> some View {
        let selected = controller.mode == mode
        return Button {
            Task { await controller.set(mode) }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: selected ? 0.22 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(selected ? 0.5 : 0), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(controller.busy)
    }
}

#Preview {
    AwakeView()
        .frame(width: 616, height: 136)
        .padding()
        .background(.black)
        .preferredColorScheme(.dark)
}
