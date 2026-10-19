import AppKit
import ShrikeCore

/// A persistent session-only notice; retry uses the same store identity.
@MainActor
final class PersistenceBanner: NSStackView {
    private let store: MetadataStore
    private let message = NSTextField(wrappingLabelWithString: "Ratings storage is unavailable. New ratings and flags use temporary storage for this session.")
    private let retry = NSButton(title: "Retry Storage", target: nil, action: nil)
    private let details = NSButton(title: "Details…", target: nil, action: nil)
    private var task: Task<Void, Never>?
    var onRecovered: (() -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?
    init(store: MetadataStore) {
        self.store = store
        super.init(frame: .zero)
        orientation = .horizontal; spacing = 8; edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        message.font = ChromeTypography.font(12)
        retry.target = self; retry.action = #selector(restore)
        details.target = self; details.action = #selector(showDetails)
        [message, retry, details].forEach { addArrangedSubview($0) }
        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Notification.Name("shrike.metadataPersistenceChanged"), object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func refresh() {
        isHidden = store.persistenceStatus.isPersistent
        onVisibilityChanged?(isHidden)
    }
    @objc private func restore() {
        guard task == nil else { return }
        retry.title = "Restoring Storage…"; retry.isEnabled = false
        let store = self.store
        task = Task { @MainActor [weak self] in
            do {
                let recovered = try await store.retryPersistentStore()
                guard !Task.isCancelled, let self else { return }
                self.refresh(); self.onRecovered?()
                NotificationCenter.default.post(name: Notification.Name("shrike.metadataPersistenceChanged"), object: nil)
                Culling.announce("Ratings storage restored. \(recovered.metadataCount) photo records and \(recovered.recentFolderCount) recent folders restored.")
            } catch { if !Task.isCancelled { self?.showError(error.localizedDescription) } }
            self?.retry.title = "Retry Storage"; self?.retry.isEnabled = true; self?.task = nil
        }
    }
    @objc private func showDetails() {
        let state = store.persistenceStatus
        let explanation = "The ratings database is unavailable. Photo-file attributes may still preserve ratings and flags when file-attribute saving is enabled and the files support writable attributes. Recent folders and decisions that cannot be saved to photo files remain temporary. Retry Storage merges the current decisions into the restored database."
        showError(([explanation] + [state.errorDescription, state.primaryURL?.path].compactMap { $0 }).joined(separator: "\n\n"))
    }
    private func showError(_ detail: String) {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "Ratings storage"; alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }
    func dispose() { task?.cancel(); task = nil; onVisibilityChanged = nil; NotificationCenter.default.removeObserver(self) }
    deinit { NotificationCenter.default.removeObserver(self) }
}
