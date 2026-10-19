import AppKit

extension ViewerWindow {
    func showContextualDecodeError(index: Int) {
        let action: String
        if index + 1 < list.count { action = "Next Photo" }
        else if index > 0 { action = "Previous Photo" }
        else { action = pairedBrowser == nil ? "Choose Another Photo…" : "Back to Browser" }
        contentRoot.showDecodeError()
        contentRoot.configureDecodeRecovery(title: action,
            revealAvailable: displayedItem.map { FileManager.default.fileExists(atPath: $0.shownURL.path) } ?? false) { [weak self] in
            guard let self else { return }
            if index + 1 < self.list.count { self.dispatch(.nextImage) }
            else if index > 0 { self.dispatch(.prevImage) }
            else if self.pairedBrowser != nil { self.showInBrowser() }
            else {
                let panel = NSOpenPanel(); panel.canChooseDirectories = false
                panel.beginSheetModal(for: self) { [weak self] response in
                    guard response == .OK, let self, let url = panel.url else { return }
                    WindowCoordinator.shared.open([url], services: self.services)
                }
            }
        }
    }
}
