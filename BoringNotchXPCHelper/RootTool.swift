//
//  RootTool.swift
//  BoringNotchXPCHelper
//
//  Root-only actions, run by the setuid-root copy of this helper installed at `RootTool.path`.
//  It accepts exactly these commands and nothing else:
//    fan <auto|3500|4500|max>    see FanControl
//    sleep <disable|enable>      `pmset -a disablesleep` — keeps the Mac awake with the lid closed
//

import Foundation

enum RootTool {
    static let path = "/usr/local/libexec/boringnotch-helper"
    /// Earlier name of the tool (fan-only); removed when the current one is installed.
    static let legacyPath = "/usr/local/libexec/boringnotch-fan"

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count == 2 else { return 2 }
        switch arguments[0] {
        case "fan":
            return FanControl.apply(arguments[1])
        case "sleep":
            guard let flag = ["disable": "1", "enable": "0"][arguments[1]] else { return 2 }
            let pmset = Process()
            pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            pmset.arguments = ["-a", "disablesleep", flag]
            do { try pmset.run() } catch { return 6 }
            pmset.waitUntilExit()
            return pmset.terminationStatus
        default:
            return 2
        }
    }
}
