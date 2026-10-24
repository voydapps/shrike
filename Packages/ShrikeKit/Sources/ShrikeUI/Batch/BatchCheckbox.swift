//
//  BatchCheckbox.swift
//  ShrikeUI
//
//  The Batch form's checkboxes. SwiftUI's checkbox Toggle
//  is an untitled NSButton with its label drawn beside it, so VoiceOver
//  and System Events found checkboxes with no title. This is a titled
//  NSButton: its accessibility title is its label ("Convert", "Resize",
//  "Keep metadata", …), and it greys out with its row like any control.
//

import AppKit
import SwiftUI

struct BatchCheckbox: NSViewRepresentable {
    let title: String
    @Binding var isOn: Bool
    /// A file name: shown as it is, shortened in the middle when the row is narrow.
    var isFileName = false

    init(_ title: String.LocalizationValue, isOn: Binding<Bool>) {
        self.title = String(localized: title)
        self._isOn = isOn
    }

    /// A checkbox titled with `fileName` exactly as written (Done view skip rows).
    init(fileName: String, isOn: Binding<Bool>) {
        self.title = fileName
        self._isOn = isOn
        self.isFileName = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(isOn: $isOn) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: context.coordinator,
                              action: #selector(Coordinator.toggled(_:)))
        // Its own size, like SwiftUI's checkbox: without this the Grid
        // rows grow taller than the old Toggle rows.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            button.setContentHuggingPriority(.required, for: axis)
            button.setContentCompressionResistancePriority(.required, for: axis)
        }
        if isFileName {
            button.lineBreakMode = .byTruncatingMiddle
            button.setContentCompressionResistancePriority(.init(250), for: .horizontal)
            button.setContentHuggingPriority(.init(250), for: .horizontal)
        }
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.isOn = $isOn
        if button.title != title { button.title = title }
        let state: NSControl.StateValue = isOn ? .on : .off
        if button.state != state { button.state = state }
        if button.isEnabled != context.environment.isEnabled {
            button.isEnabled = context.environment.isEnabled
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var isOn: Binding<Bool>

        init(isOn: Binding<Bool>) { self.isOn = isOn }

        @objc func toggled(_ sender: NSButton) {
            isOn.wrappedValue = sender.state == .on
        }
    }
}
