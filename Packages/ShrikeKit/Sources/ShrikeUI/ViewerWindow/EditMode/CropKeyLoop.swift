//
//  CropKeyLoop.swift
//  ShrikeUI
//
//  While the Crop tool is chosen, Tab moves between the
//  panel's fields and the crop frame: last panel field → frame → first
//  panel field (Shift-Tab the other way). The filmstrip is outside that
//  loop while editing (Tab after H used to walk every
//  thumbnail and never reached the frame).
//

import AppKit

extension EditModeController {

    /// Where Tab (`forward`) or Shift-Tab goes from `view` while Crop is
    /// chosen; nil when the window's own key-view loop decides.
    func cropKeyLoopTarget(leaving view: NSView, forward: Bool) -> NSView? {
        guard isActive, currentTool == .crop, !cropOverlay.isHiddenOrHasHiddenAncestor,
              cropOverlay.window != nil else { return nil }
        let fields = cropPanelKeyViews()
        guard let first = fields.first, let last = fields.last else { return nil }
        if view === cropOverlay { return forward ? first : last }
        guard view.isDescendant(of: parameterPanel) else { return nil }
        if forward, view === last { return cropOverlay }
        if !forward, view === first { return cropOverlay }
        return nil
    }

    /// The panel's key views in loop order, starting after the frame (with
    /// Full Keyboard Access off these are the text fields only).
    private func cropPanelKeyViews() -> [NSView] {
        Self.keyViews(after: cropOverlay, inside: parameterPanel)
    }

    /// The views inside `container` met while walking the valid key-view
    /// loop once from `start` (pure walk; bounded).
    static func keyViews(after start: NSView, inside container: NSView, limit: Int = 2_000) -> [NSView] {
        var result: [NSView] = []
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(start)]
        var next = start.nextValidKeyView
        while let view = next, seen.insert(ObjectIdentifier(view)).inserted, seen.count < limit {
            if view.isDescendant(of: container) { result.append(view) }
            next = view.nextValidKeyView
        }
        return result
    }
}
