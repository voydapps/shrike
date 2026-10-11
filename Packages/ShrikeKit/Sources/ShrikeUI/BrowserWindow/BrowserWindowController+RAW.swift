//
//  BrowserWindowController+RAW.swift
//  ShrikeUI
//
//  ⌥R and the RAW chip in the Browser: the view-only switch between the
//  selected pair's JPEG and RAW, as in the viewer (spec 24 §4). The big
//  preview (Filmstrip) and the info panel show the RAW file; nothing is
//  saved. Another selection ends it.
//

import AppKit
import ShrikeCore

extension BrowserWindowController {

    /// "Show RAW File" / "Show JPEG File" (the pair's display kind).
    var rawSwitchMenuTitle: String {
        guard contentController.isShowingRAW, let pair = contentController.rawSwitchCandidate else {
            return "Show RAW File"
        }
        return "Show \(ViewerWindow.kindName(of: pair.url)) File"
    }

    public func browserContentRequestsRAWSwitch() { toggleRAWFile() }

    func toggleRAWFile() {
        let content = contentController
        guard let pair = content.rawSwitchCandidate else { return }
        if content.isShowingRAW {
            rawSwitchTask?.cancel()
            content.showRAW(nil)
            refreshSelectionInfo()
            return
        }
        guard let rawURL = pair.group.rawURL else { return }
        rawSwitchTask?.cancel()
        let cache = services.thumbnailCache
        rawSwitchTask = Task { @MainActor [weak self] in
            // macOS has to open this RAW and draw it before anything changes.
            let readable = await Task.detached(priority: .userInitiated) {
                ViewerWindow.canOpenImage(rawURL)
            }.value
            var picture = false
            if readable {
                picture = (try? await cache.thumbnail(
                    for: FileImageSource(url: rawURL), maxPixelSize: Self.rawPreviewProbePixels)) != nil
            }
            let item: BrowserItem? = picture ? try? BrowserItem.make(from: rawURL) : nil
            guard !Task.isCancelled, let self, self.contentController.rawSwitchCandidate?.url == pair.url else { return }
            guard let item else {
                self.toast(ViewerWindow.rawCannotOpenCopy)
                return
            }
            self.contentController.showRAW(item)
            self.refreshSelectionInfo()
        }
    }

    /// A small decode proves the RAW draws before the switch.
    static let rawPreviewProbePixels = 256
}
