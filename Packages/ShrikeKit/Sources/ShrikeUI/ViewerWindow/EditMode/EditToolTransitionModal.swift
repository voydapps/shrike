import AppKit

/// A decision about pending tool changes, rather than the whole photo.
/// Crop/Resize Apply accepts geometry before this decision; live-preview tools
/// keep their existing visit scope.
@MainActor
enum EditToolTransitionModal {
    enum Choice: Sendable { case keep, cancel, discard }
    struct Content: Equatable {
        let outgoing: EditTool
        let destination: EditTool
        private var hasExplicitApply: Bool { outgoing == .crop || outgoing == .resize }
        var message: String {
            "Keep \(hasExplicitApply ? "pending " : "")\(EditChromeTools.name(outgoing)) changes before switching to \(EditChromeTools.name(destination))?"
        }
        var information: String {
            if hasExplicitApply {
                return "Keep adds these changes to your edit. Discard Changes removes only the pending \(EditChromeTools.name(outgoing)) changes. Applied changes and earlier edits stay. The photo isn't saved yet."
            }
            return "Keep these changes in your edit, or discard the changes made since you opened \(EditChromeTools.name(outgoing)). Earlier edits will stay. The photo isn't saved yet."
        }
    }
    /// Deliberate answers in component tests; nil always presents the native sheet.
    static var responderForTesting: ((Content) -> Choice)?
    static var presenterForTesting: ((Content, @escaping @MainActor (Choice) -> Void) -> Void)?

    static func makeAlert(_ content: Content) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = content.message
        alert.informativeText = content.information
        alert.addButton(withTitle: "Keep Changes").keyEquivalent = "\r"
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let discard = alert.addButton(withTitle: "Discard Changes")
        discard.keyEquivalent = "d"; discard.keyEquivalentModifierMask = [.command]
        return alert
    }

    @discardableResult
    static func show(on window: NSWindow?, content: Content,
                     completion: @escaping @MainActor (Choice) -> Void) -> NSAlert? {
        if let presenterForTesting { presenterForTesting(content, completion); return nil }
        if let responderForTesting { completion(responderForTesting(content)); return nil }
        guard let window else { completion(.cancel); return nil }
        let alert = makeAlert(content)
        alert.beginSheetModal(for: window) { response in
            Task { @MainActor in
                completion(response == .alertFirstButtonReturn ? .keep : (response == .alertThirdButtonReturn ? .discard : .cancel))
            }
        }
        return alert
    }
}
