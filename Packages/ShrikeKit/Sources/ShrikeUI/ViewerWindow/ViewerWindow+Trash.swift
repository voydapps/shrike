//
//  ViewerWindow+Trash.swift
//  ShrikeUI
//
//  Delete to Trash in the viewer: the displayed group
//  leaves the list and the next image shows in the same main-actor turn;
//  the file operation runs after, queued in press order. Undo puts the
//  group back at its old index. The empty state shows when the list runs
//  out.
//

import AppKit
import ShrikeCore
import ShrikeIO

extension ViewerWindow {

    // MARK: - Trash

    /// Removes `item`'s group from the list at once, shows the item at the
    /// same index (or the one before, at the end), then moves the files to
    /// the Trash. Presses made while an earlier trash still runs are queued
    /// in order; each one targets the item shown when it was pressed.
    func trash(_ item: DisplayedItem) {
        guard let index = list.index(of: item.group.primary),
              let group = list[index] else { return }
        let removed = list.remove(primaries: [group.primary])
        let folder = group.primary.deletingLastPathComponent()
        evictFromDecodeCache(group.primary)
        showAfterRemoval(at: index, folder: folder)

        let ops = fileOps
        let previous = trashChain
        trashChain = Task { @MainActor [weak self] in
            await previous?.value
            do {
                let receipt = try await ops.trash([group])
                self?.didTrash(receipt, removed: removed)
            } catch {
                await self?.trashFailed(removed, error: error)
            }
        }
    }

    /// Waits for every queued trash (tests).
    func waitForPendingTrash() async {
        await trashChain?.value
    }

    private func didTrash(_ receipt: TrashReceipt, removed: [RemovedGroup]) {
        windowUndoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.undoTrash(receipt, removed: removed) }
        }
        windowUndoManager.setActionName("Move to Trash")
        contentRoot.toast(
            ToastContent(FileActionCopy.movedToTrash(receipt.trashedGroups), actionTitle: "Undo")
        ) { [weak self] in
            self?.performUndo()
        }
    }

    /// No Trash on the volume → the permanent-delete alert (Cancel puts the item back).
    /// Any other error → the item goes back where it was, toast T2.
    private func trashFailed(_ removed: [RemovedGroup], error: any Error) async {
        guard let entry = removed.first else { return }
        if case .noTrash? = error as? FileOpsError {
            let choice = await presentFileAlert(
                message: "“\(entry.group.displayName)” can't be moved to the Trash.",
                information: "This volume doesn't have a Trash. Delete it now? You can't undo this.",
                buttons: [ShrikeAlert.Button("Delete", role: .destructive), .cancel()]
            )
            if choice == 0 {
                do {
                    try await fileOps.deleteImmediately(entry.group)
                    return
                } catch {
                    reinsert(removed)
                    contentRoot.toast(ToastContent(
                        FileActionCopy.deleteFailed(entry.group, error: error), kind: .error
                    ))
                    return
                }
            }
            reinsert(removed)
            return
        }
        reinsert(removed)
        contentRoot.toast(ToastContent(
            FileActionCopy.trashFailed(entry.group, error: error), kind: .error
        ))
    }

    /// Puts removed groups back at their old indices and shows the first.
    func reinsert(_ removed: [RemovedGroup]) {
        guard let first = removed.first else { return }
        list.insert(removed)
        hideEmptyState()
        reloadList(showing: min(first.index, list.count - 1))
    }

    func undoTrash(_ receipt: TrashReceipt, removed: [RemovedGroup]) {
        // Redo trashes the same files again. Registered inside the undo so
        // it lands on the redo stack.
        windowUndoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.redoTrash(receipt.trashedGroups) }
        }
        windowUndoManager.setActionName("Move to Trash")
        let ops = fileOps
        let name = removed.first?.group.displayName ?? ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await ops.restore(receipt)
                guard !result.groups.isEmpty else {
                    self.contentRoot.toast(ToastContent(FileActionCopy.noLongerInTrash(name), kind: .error))
                    return
                }
                let restored = zip(removed, result.groups).map {
                    RemovedGroup(index: $0.index, group: $1)
                }
                self.reinsert(restored)
                self.contentRoot.toast(ToastContent(
                    FileActionCopy.putBack(original: removed[0].group, restored: restored[0].group)
                ))
            } catch {
                self.contentRoot.toast(ToastContent(FileActionCopy.noLongerInTrash(name), kind: .error))
            }
        }
    }

    private func redoTrash(_ groups: [ImageGroup]) {
        guard let group = groups.first,
              let index = list.index(of: group.primary),
              let current = list[index]
        else { return }
        trash(DisplayedItem(group: current, listIndex: index, generation: list.generation))
    }

    // MARK: - After a removal

    /// Shows the item now at `index` (clamped), or the empty state.
    func showAfterRemoval(at index: Int, folder: URL) {
        displayedItem = nil
        if list.isEmpty {
            reloadList(showing: 0)
            showEmptyState(ViewerEmptyStateView.noMoreImages(in: folder), folder: folder)
        } else {
            reloadList(showing: min(index, list.count - 1))
        }
    }

    func evictFromDecodeCache(_ url: URL) {
        let navigation = self.navigation
        Task { await navigation.decodeQueue.evict(url: url) }
    }

    // MARK: - Empty state

    var isShowingEmptyState: Bool { emptyStateView?.isHidden == false }

    func showEmptyState(_ text: String, folder: URL) {
        let view: ViewerEmptyStateView
        if let existing = emptyStateView {
            view = existing
        } else {
            view = ViewerEmptyStateView()
            view.translatesAutoresizingMaskIntoConstraints = false
            contentRoot.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: contentRoot.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: contentRoot.centerYAnchor),
                view.widthAnchor.constraint(lessThanOrEqualTo: contentRoot.widthAnchor, constant: -40),
            ])
            emptyStateView = view
        }
        view.onShowFolder = { [weak self] in self?.showFolderInBrowser(folder) }
        view.onClose = { [weak self] in self?.performClose(nil) }
        view.setTitle(text)
        view.isHidden = false
        contentRoot.setEmptyStateChrome(true)
        title = "Shrike"
        subtitle = ""
        Culling.announce(text)
    }

    func hideEmptyState() {
        guard let view = emptyStateView, !view.isHidden else { return }
        view.isHidden = true
        contentRoot.setEmptyStateChrome(false)
    }

    /// "Show Folder in Browser": the paired Browser, or a new one.
    private func showFolderInBrowser(_ folder: URL) {
        if let browser = pairedBrowser {
            orderOut(nil)
            browser.window?.makeKeyAndOrderFront(nil)
            scheduleHiddenTrim()
            return
        }
        let browser = WindowCoordinator.shared.openBrowser(at: folder, selecting: nil, services: services)
        pair(with: browser)
        browser.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Alerts

    /// A sheet on this window; returns the index of the chosen button in
    /// `buttons`. Tests answer through `alertResponderForTesting`.
    func presentFileAlert(message: String, information: String, buttons: [ShrikeAlert.Button]) async -> Int? {
        if let responder = alertResponderForTesting { return responder(message) }
        return await ShrikeAlert.run(message: message, information: information, buttons: buttons, on: self)
    }
}

/// "No more images in “Italy 2026”." with Show Folder in Browser · Close
/// Window. Title 17 pt semibold white on the viewer black; buttons
/// 12 pt below, regular size, 8 pt apart.
final class ViewerEmptyStateView: NSView {

    static func noMoreImages(in folder: URL) -> String {
        "No more images in “\(folder.lastPathComponent)”."
    }

    static func folderGone(_ folder: URL) -> String {
        "“\(folder.lastPathComponent)” is no longer available."
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private(set) lazy var showFolderButton = NSButton(
        title: "Show Folder in Browser", target: self, action: #selector(showFolder(_:)))
    private(set) lazy var closeButton = NSButton(
        title: "Close Window", target: self, action: #selector(close(_:)))
    var onShowFolder: (() -> Void)?
    var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        showFolderButton.controlSize = .regular
        closeButton.controlSize = .regular
        // Standalone buttons over the canvas are glass on
        // macOS 26 and push buttons on 14 / 15.
        if #available(macOS 26, *) {
            showFolderButton.bezelStyle = .glass
            closeButton.bezelStyle = .glass
        }
        let buttons = NSStackView(views: [showFolderButton, closeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [titleLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        appearance = NSAppearance(named: .darkAqua)
    }

    required init?(coder: NSCoder) { fatalError() }

    var title: String { titleLabel.stringValue }

    func setTitle(_ text: String) {
        titleLabel.stringValue = text
        titleLabel.setAccessibilityLabel(text)
    }

    @objc private func showFolder(_ sender: Any?) { onShowFolder?() }
    @objc private func close(_ sender: Any?) { onClose?() }
}
