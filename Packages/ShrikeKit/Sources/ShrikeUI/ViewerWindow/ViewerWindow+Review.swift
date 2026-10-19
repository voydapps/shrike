import AppKit
import ShrikeCore
import ShrikeRendering

/// Native popover content owns its padding and fits all wrapped text. Keeping
/// the label inside a container also prevents its glyphs touching the arrow.
@MainActor
final class BrowserReturnHintController: NSViewController {
    private let text: String
    private let contentWidth: CGFloat = 280
    private let horizontalInset: CGFloat = 14
    private var chromeObservation: ChromeTextObservation?

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = ChromeTypography.font(12)
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = contentWidth - 2 * horizontalInset
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: contentWidth),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontalInset),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontalInset),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        view = container
        chromeObservation = ChromeTextObservation(root: container) { [weak self] in self?.fitContent() }
        fitContent()
    }

    private func fitContent() {
        let fitted = view.fittingSize
        preferredContentSize = fitted
        view.setFrameSize(fitted)
        view.layoutSubtreeIfNeeded()
    }
}

extension ViewerWindow {
    func configureReview() {
        contentRoot.imageView.onFirstImagePresented = { [weak self] in
            self?.browserReturnHintReady = true
            self?.showBrowserReturnHint()
        }
        if Prefs.reviewControlsVisible { wireReviewControls() }
        NotificationCenter.default.addObserver(self, selector: #selector(reviewPreferencesChanged), name: .shrikeChromePreferencesChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reviewStorageChanged), name: Notification.Name("shrike.metadataPersistenceChanged"), object: nil)
        let banner = PersistenceBanner(store: services.metadataStore)
        reviewPersistenceBanner = banner
        banner.onRecovered = { [weak self] in self?.loadCullingRecords() }
        contentRoot.installPersistenceBanner(banner)
        let queue = navigation.decodeQueue
        contentRoot.imageView.resources = queue.resources
        contentRoot.imageView.resourceOwner = queue.resourceOwner
        imagePressureObservation = queue.resources.observePressure { [weak self] pressure in
            guard pressure != .normal else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.didTearDown else { return }
                let view = self.contentRoot.imageView
                // Actual/zoom detail and viewport refetches serve the current
                // photo. Only detail no longer needed at stable Fit is optional.
                if view.isAtFit, !view.isZoomAnimating {
                    self.cancelFullResolution()
                    view.dropFullResolution()
                }
                // DecodeQueue's pressure observer compacts its optional window.
                // Purging here would cancel the required current decode too.
                self.onImagePressureHandledForTesting?()
            }
        }
        refreshReviewRecord()
    }
    private func wireReviewControls() {
        contentRoot.installReviewControls()
        contentRoot.reviewControls.onNavigate = { [weak self] next in self?.dispatch(next ? .nextImage : .prevImage) }
        contentRoot.reviewControls.onRate = { [weak self] stars in self?.rateDisplayed(stars) }
        contentRoot.reviewControls.onFlag = { [weak self] in self?.toggleFlagDisplayed() }
    }
    func showBrowserReturnHint() {
        guard browserReturnHintReady, !didTearDown, !Prefs.hasSeenBrowserReturnHint, returnHintPopover == nil,
              !contentRoot.isEditModeActive, let browser = pairedBrowser,
              let bar = toolbarController, toolbar === bar.toolbar,
              let anchor = bar.returnAnchor else { return }
        let folder = browser.currentFolder?.lastPathComponent ?? "Browser"
        let shortcut = ShortcutTable.displayString(for: .showInBrowser, context: .viewer, preset: Prefs.shortcutPreset)
        let controller = BrowserReturnHintController(text: "Back to \(folder) · \(shortcut)")
        _ = controller.view
        let popover = NSPopover(); popover.behavior = .transient; popover.contentViewController = controller
        popover.animates = !ReduceMotion.isOn
        returnHintPopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        guard popover.isShown else { returnHintPopover = nil; return }
        Prefs.hasSeenBrowserReturnHint = true
    }

    @objc func toggleReviewControls(_ sender: Any?) {
        Prefs.reviewControlsVisible.toggle()
        NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
    }
    @objc private func reviewPreferencesChanged() {
        if Prefs.reviewControlsVisible { wireReviewControls() }
        contentRoot.refreshReviewVisibility(); ChromeTypography.update(contentRoot)
        contentRoot.refreshEditPrimaryTypography(); refreshReviewRecord()
    }
    @objc private func reviewStorageChanged() { refreshReviewRecord(); loadCullingRecords() }
    func refreshReviewRecord() {
        guard Prefs.reviewControlsVisible else { return }
        let record = displayedItem.flatMap { cullingRecords[$0.group.primary] } ?? FileRecord()
        contentRoot.reviewControls.update(record: record, durable: services.metadataStore.persistenceStatus.isPersistent)
    }
    func reviewJump(to index: Int) {
        coalesceNav { [weak self] in await self?.navigate(to: index) }
    }
}
