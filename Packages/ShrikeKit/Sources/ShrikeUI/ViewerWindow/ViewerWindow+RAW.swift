//
//  ViewerWindow+RAW.swift
//  ShrikeUI
//
//  Spec 24 §4: the view-only RAW <-> primary switch for a pair.
//
//  The switch swaps the shown index's source in the window's own list for
//  `FileImageSource(url: group.rawURL)` and navigates to it, so the RAW goes
//  through the same decode path as any photo (previews, hairline, cache,
//  histogram, full resolution). Nothing is saved: moving to another photo,
//  or any list reload, builds the sources from the primaries again.
//

import AppKit
import ImageIO
import ShrikeCore

extension ViewerWindow {

    // MARK: - State

    /// The group has a RAW companion next to its primary (not a RAW-only
    /// photo), and the grouping preference folded them into one item.
    var hasRAWCompanionShown: Bool {
        guard let group = displayedItem?.group else { return false }
        return !group.primaryIsRAW && group.rawURL != nil
    }

    var canToggleRAWFile: Bool { hasRAWCompanionShown && !contentRoot.isEditModeActive }

    /// "Show RAW File" / "Show JPEG File" (the primary's kind).
    var rawSwitchMenuTitle: String {
        guard let item = displayedItem, item.isRAWShown else { return "Show RAW File" }
        return "Show \(Self.kindName(of: item.group.primary)) File"
    }

    /// "JPEG", "HEIC", "TIFF", "PNG": the label of the primary file's kind.
    static func kindName(of url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "jpe", "jfif": return "JPEG"
        case "heic", "heif": return "HEIC"
        case "tif", "tiff": return "TIFF"
        case "png": return "PNG"
        case let other where !other.isEmpty: return other.uppercased()
        default: return "image"
        }
    }

    /// The chip's left label: "JPG", "HEIC", "TIFF", "PNG".
    static func chipKindName(of url: URL) -> String {
        let kind = kindName(of: url)
        return kind == "JPEG" ? "JPG" : kind
    }

    static let rawEditBlockedCopy = "RAW files are not changed. Switch to the JPEG to edit."
    static let rawCannotOpenCopy = "macOS can\u{2019}t open this RAW file."

    /// Actions that would write or edit the shown file; refused while the
    /// RAW is shown.
    static func writesTheShownFile(_ action: ViewerAction) -> Bool {
        switch action {
        case .rotateLeft, .rotateRight, .rotate180, .flipHorizontal, .flipVertical,
             .rotateLossless, .openEditMode, .enterEditMode, .crop, .resize, .colorAdjust,
             .selectEditTool, .saveEditedFile, .saveEditedFileAs, .autoLevels:
            return true
        default:
            return false
        }
    }

    /// Dispatch guard: toast and stop. Returns true when it refused.
    func refuseWriteWhileRAWShown(_ action: ViewerAction) -> Bool {
        guard displayedItem?.isRAWShown == true, !contentRoot.isEditModeActive,
              Self.writesTheShownFile(action) else { return false }
        contentRoot.toast(Self.rawEditBlockedCopy)
        return true
    }

    // MARK: - Switch

    /// ⌥R, the Image menu line, the context menu line and the pill chip.
    func toggleRAWFile() {
        guard canToggleRAWFile, let item = displayedItem else { return }
        let index = item.listIndex
        if item.isRAWShown {
            swapShownSource(at: index, to: item.group.primary, group: item.group)
            return
        }
        guard let raw = item.group.rawURL else { return }
        rawSwitchTask?.cancel()
        rawSwitchTask = Task { @MainActor [weak self] in
            // macOS has to be able to open this RAW before anything changes.
            let readable = await Task.detached(priority: .userInitiated) { Self.canOpenImage(raw) }.value
            guard !Task.isCancelled, let self, self.displayedItem == item else { return }
            guard readable else {
                self.contentRoot.toast(Self.rawCannotOpenCopy)
                return
            }
            self.swapShownSource(at: index, to: raw, group: item.group)
        }
    }

    /// True when ImageIO finds at least one image in the file.
    nonisolated static func canOpenImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    /// The sources of the list: every group's primary, with `index` showing
    /// `url` instead.
    private func sources(replacing index: Int, with url: URL?) -> [any ImageSource] {
        list.groups.enumerated().map { i, group in
            FileImageSource(url: i == index ? (url ?? group.primary) : group.primary)
        }
    }

    private func swapShownSource(at index: Int, to url: URL, group: ImageGroup) {
        let sources = sources(replacing: index, with: url)
        intent.setNavigation(list: sources, currentIndex: index)
        // Pixel positions mean nothing across two files' sizes: Fit again.
        if !contentRoot.imageView.isAtFit { contentRoot.imageView.zoomToFit() }
        // Pill, title and marks follow at once.
        contentRoot.showNavigationPosition(index: index, total: sources.count, filename: url.lastPathComponent)
        contentRoot.setPositionMarks(positionMarks(for: index))
        coalesceNav { [weak self] in
            guard let self else { return }
            await self.navigation.setNavigation(list: sources, currentIndex: index)
            if Task.isCancelled { return }
            await self.navigate(to: index)
            // A RAW that opened but did not decode: back to the primary.
            if url != group.primary, self.contentRoot.isShowingDecodeError {
                self.contentRoot.toast(Self.rawCannotOpenCopy)
                self.swapShownSource(at: index, to: group.primary, group: group)
            }
        }
    }

    /// Leaving a photo that shows its RAW: its slot shows the primary again
    /// before the move (spec 24 §4.1). `to` is where the user is going.
    func restorePrimarySourcesBeforeLeaving(to target: Int) async {
        guard let item = displayedItem, item.isRAWShown, item.listIndex != target else { return }
        let sources = sources(replacing: -1, with: nil)
        intent.setNavigation(list: sources, currentIndex: target)
        await navigation.setNavigation(list: sources, currentIndex: item.listIndex)
    }
}
