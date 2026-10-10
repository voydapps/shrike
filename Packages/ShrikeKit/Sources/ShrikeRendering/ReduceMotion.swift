//
//  ReduceMotion.swift
//  ShrikeRendering
//
//  The one place Shrike asks whether Reduce Motion is on.
//  Read each time (the user can switch it while Shrike runs); tests set
//  `overrideForTesting` instead of the system setting.
//

import AppKit

@MainActor
public enum ReduceMotion {

    /// Tests: forces Reduce Motion on or off; nil reads the system.
    public static var overrideForTesting: Bool?

    /// True when the system (or a test) asks for less motion.
    public static var isOn: Bool {
        overrideForTesting ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
