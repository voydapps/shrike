import AppKit
import ShrikeCore

extension Notification.Name {
    static let shrikeChromePreferencesChanged = Notification.Name("shrike.chromePreferencesChanged")
}

/// Shared task-chrome scale. Image geometry and image-only HUDs are untouched.
enum ChromeTypography {
    static func size(_ standard: CGFloat) -> CGFloat { standard + (Prefs.largerChrome ? 2 : 0) }
    static func font(_ standard: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size(standard), weight: weight)
    }
    static var targetHeight: CGFloat { Prefs.largerChrome ? 32 : 28 }
    /// Use once for a fresh native control whose default font has not already
    /// been built through `font`/`size`; retain AppKit's face and weight.
    @MainActor static func initializeNativeFont(_ control: NSControl) {
        guard let font = control.font else { return }
        control.font = NSFontManager.shared.convert(font, toSize: size(font.pointSize))
    }
    @MainActor private static let baselines = NSMapTable<NSView, NSNumber>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    @MainActor static func register(_ root: NSView) {
        if let control = root as? NSControl, baselines.object(forKey: root) == nil,
           let font = control.font, font.pointSize <= 17 {
            baselines.setObject(NSNumber(value: Double(font.pointSize - (Prefs.largerChrome ? 2 : 0))), forKey: root)
        }
        root.subviews.forEach(register)
    }
    @MainActor static func update(_ root: NSView) {
        if let outline = root as? NSOutlineView { outline.rowHeight = targetHeight }
        let controls = [root]
        for view in controls {
            if let field = view as? NSControl, let font = field.font,
               baselines.object(forKey: field) != nil || font.pointSize <= 17 {
                let base = baselines.object(forKey: field)?.doubleValue ?? Double(font.pointSize - (Prefs.largerChrome ? 2 : 0))
                baselines.setObject(NSNumber(value: base), forKey: field)
                let updated = NSFontManager.shared.convert(font, toSize: size(CGFloat(base)))
                field.font = updated
                // The active AppKit field editor is outside this view subtree.
                if let textField = field as? NSTextField { textField.currentEditor()?.font = updated }
            }
            for c in view.constraints where c.identifier?.hasPrefix("shrike.chromeSize.") == true {
                let parts = c.identifier!.split(separator: ".")
                if parts.count == 4, let normal = Double(parts[2]), let large = Double(parts[3]) {
                    c.constant = Prefs.largerChrome ? large : normal
                }
            }
        }
        for child in root.subviews { update(child) }
        root.needsLayout = true
    }
    @MainActor static func scaled(_ constraint: NSLayoutConstraint, normal: CGFloat, large: CGFloat) -> NSLayoutConstraint {
        constraint.identifier = "shrike.chromeSize.\(Int(normal)).\(Int(large))"
        constraint.constant = Prefs.largerChrome ? large : normal
        return constraint
    }
}

/// The owner stores this observer; notification delivery never owns a window.
@MainActor
final class ChromeTextObservation: NSObject {
    private weak var root: NSView?
    private let afterUpdate: (() -> Void)?
    init(root: NSView, afterUpdate: (() -> Void)? = nil) {
        self.root = root
        self.afterUpdate = afterUpdate
        super.init()
        ChromeTypography.register(root)
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: .shrikeChromePreferencesChanged, object: nil)
    }
    @objc private func changed() {
        guard let root else { return }
        ChromeTypography.update(root)
        afterUpdate?()
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}
