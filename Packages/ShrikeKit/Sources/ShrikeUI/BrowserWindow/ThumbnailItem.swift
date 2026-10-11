//
//  ThumbnailItem.swift
//  ShrikeUI
//
//  `NSCollectionViewItem` subclass for the browser grid + filmstrip.
//  Loads thumbnails lazily via `ThumbnailCache` — we kick off a `Task` in
//  `willDisplay` (via `configure(item:services:)`) and cancel in
//  `didEndDisplaying` to respect sliding-window decode.
//

import AppKit
import Foundation
import ShrikeCore
import ShrikeIO
import ShrikeRendering

@MainActor
public final class ThumbnailItem: NSCollectionViewItem {

    // MARK: - Identifier

    public static let reuseIdentifier = NSUserInterfaceItemIdentifier("Browser.ThumbnailItem")

    // MARK: - Geometry

    /// The ring is drawn 3 pt outside the card, so the card sits 3 pt in
    /// from the cell's edges and the ring never leaves the cell.
    static let ringWidth: CGFloat = 3
    static let cardRadius: CGFloat = 10
    static let ringRadius: CGFloat = 13
    static let nameFontSize: CGFloat = 12
    static let capsuleHeight: CGFloat = 18
    static let capsulePadding: CGFloat = 6
    /// "Can't preview" shows only on cells at least this wide.
    static let failureTextMinWidth: CGFloat = 96
    /// A thumbnail fades in over 80 ms (`motion.instant`).
    static let fadeInDuration: TimeInterval = 0.08
    static let fadeInKey = "shrike.thumbnailFadeIn"

    // MARK: - Subviews

    private let imageBackground: NSView
    private let thumbnailView: NSImageView
    private let nameLabel: NSTextField
    private let formatBadge: NSTextField
    // Badges: flag top-left, badge row top-right (RAW chip,
    // livephoto, pencil), stars bottom-left, tag dots after the name.
    private let flagView = NSImageView()
    private let starsLabel = NSTextField(labelWithString: "")
    private let badgeRow = NSStackView()
    private let rawChipView = NSImageView()
    /// Over the RAW chip: a click shows the pair's RAW file (⌥R).
    private let rawChipButton = PillChipButton()
    /// Set by the Browser: the chip was clicked.
    var onRAWChip: (() -> Void)?
    private let livePhotoView = NSImageView()
    private let pencilView = NSImageView()
    private let tagDotsView = NSImageView()
    private let nameRow = NSStackView()
    /// Selection ring, 3 pt outside the card.
    private let ringView = PassThroughView()
    /// Spec 24 §2 (the filmstrip view's strip): the hover ring on the card's
    /// edge and a white veil on the photo.
    private let hoverRing = PassThroughView()
    private let hoverOverlay = PassThroughView()
    /// The pointer is over this cell (set by `BrowserCollectionView`).
    private(set) var isHovered = false
    /// The file name as the tooltip (the filmstrip view's strip).
    var showsNameTooltip = false {
        didSet { updateToolTip() }
    }
    /// Capsule behind the name when selected.
    private let nameCapsule = PassThroughView()
    /// Decode failure: triangle, then "Can't preview" on big cells.
    private let failureIcon = NSImageView()
    private let failureLabel = NSTextField(labelWithString: "Can't preview")
    private let failureStack = NSStackView()

    private var loadTask: Task<Void, Never>?
    private var currentItem: BrowserItem?
    private var colorObserver: LiveColorObserver?
    /// True when the thumbnail could not be read.
    private(set) var isFailed = false
    /// Test seam: the window counts as key when set.
    var isKeyOverrideForTesting: Bool?

    // MARK: - Init

    public override func loadView() {
        let root = ThumbnailCellView(frame: NSRect(x: 0, y: 0, width: 180, height: 220))
        root.wantsLayer = true
        root.onUpdateLayer = { [weak self] in self?.applyColors() }
        root.onLayout = { [weak self] in self?.updateFailureLabel() }
        view = root
        colorObserver = LiveColorObserver(view: root)

        imageBackground.translatesAutoresizingMaskIntoConstraints = false
        imageBackground.wantsLayer = true
        imageBackground.layer?.cornerRadius = Self.cardRadius
        imageBackground.layer?.borderWidth = 0
        root.addSubview(imageBackground)

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 8
        thumbnailView.layer?.masksToBounds = true
        imageBackground.addSubview(thumbnailView)

        // The hover veil: above the photo, below the badges.
        hoverOverlay.translatesAutoresizingMaskIntoConstraints = false
        hoverOverlay.wantsLayer = true
        hoverOverlay.layer?.cornerRadius = 8
        hoverOverlay.layer?.masksToBounds = true
        hoverOverlay.layer?.backgroundColor = StripHoverLook.overlayColor
        hoverOverlay.layer?.opacity = 0
        imageBackground.addSubview(hoverOverlay)

        formatBadge.translatesAutoresizingMaskIntoConstraints = false
        formatBadge.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        formatBadge.textColor = .white
        formatBadge.drawsBackground = true
        formatBadge.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        formatBadge.isBezeled = false
        formatBadge.isEditable = false
        formatBadge.alignment = .center
        formatBadge.stringValue = ""
        formatBadge.isHidden = true
        imageBackground.addSubview(formatBadge)

        failureIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        failureIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        failureIcon.contentTintColor = .tertiaryLabelColor
        failureLabel.font = .systemFont(ofSize: 11)
        failureLabel.textColor = .secondaryLabelColor
        failureLabel.alignment = .center
        failureStack.orientation = .vertical
        failureStack.spacing = 4
        failureStack.alignment = .centerX
        failureStack.addArrangedSubview(failureIcon)
        failureStack.addArrangedSubview(failureLabel)
        failureStack.translatesAutoresizingMaskIntoConstraints = false
        failureStack.isHidden = true
        imageBackground.addSubview(failureStack)

        nameCapsule.translatesAutoresizingMaskIntoConstraints = false
        nameCapsule.wantsLayer = true
        nameCapsule.layer?.cornerRadius = Self.capsuleHeight / 2
        nameCapsule.isHidden = true
        root.addSubview(nameCapsule)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: Self.nameFontSize)
        nameLabel.textColor = .labelColor
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.drawsBackground = false
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.alignment = .center
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        tagDotsView.setContentCompressionResistancePriority(.required, for: .horizontal)
        tagDotsView.isHidden = true
        nameRow.orientation = .horizontal
        nameRow.spacing = 4
        nameRow.alignment = .centerY
        nameRow.translatesAutoresizingMaskIntoConstraints = false
        nameRow.addArrangedSubview(nameLabel)
        nameRow.addArrangedSubview(tagDotsView)
        root.addSubview(nameRow)

        flagView.translatesAutoresizingMaskIntoConstraints = false
        flagView.image = Badges.symbol("flag.fill", pointSize: 12, color: Badges.flagColor)
        flagView.isHidden = true
        Badges.applyThumbnailShadow(to: flagView)
        imageBackground.addSubview(flagView)

        starsLabel.translatesAutoresizingMaskIntoConstraints = false
        starsLabel.font = .systemFont(ofSize: 10)
        starsLabel.textColor = Badges.ratingColor
        starsLabel.isHidden = true
        Badges.applyThumbnailShadow(to: starsLabel)
        imageBackground.addSubview(starsLabel)

        // Right to left: RAW chip, livephoto, pencil — so the stack's
        // order (left to right) is pencil, livephoto, RAW.
        let onPhoto = NSColor.white.withAlphaComponent(0.9)
        rawChipView.image = Badges.rawChipImage(fontSize: 9, height: 14, color: onPhoto)
        livePhotoView.image = Badges.symbol("livephoto", pointSize: 12, color: onPhoto)
        pencilView.image = Badges.symbol("pencil", pointSize: 12, color: onPhoto)
        for view in [pencilView, livePhotoView, rawChipView] {
            view.isHidden = true
            badgeRow.addArrangedSubview(view)
        }
        badgeRow.orientation = .horizontal
        badgeRow.spacing = 4
        badgeRow.alignment = .centerY
        badgeRow.translatesAutoresizingMaskIntoConstraints = false
        Badges.applyThumbnailShadow(to: badgeRow)
        imageBackground.addSubview(badgeRow)

        rawChipButton.translatesAutoresizingMaskIntoConstraints = false
        rawChipButton.target = self
        rawChipButton.action = #selector(rawChipTapped(_:))
        rawChipButton.isHidden = true
        rawChipButton.setAccessibilityLabel("Show RAW File")
        rawChipButton.toolTip = LiveTooltips.text(.toggleRAWFile, context: .browser, preset: Prefs.shortcutPreset,
                                                  title: "Show RAW File")
        imageBackground.addSubview(rawChipButton)
        NSLayoutConstraint.activate([
            rawChipButton.centerXAnchor.constraint(equalTo: rawChipView.centerXAnchor),
            rawChipButton.centerYAnchor.constraint(equalTo: rawChipView.centerYAnchor),
            rawChipButton.widthAnchor.constraint(equalTo: rawChipView.widthAnchor, constant: 8),
            rawChipButton.heightAnchor.constraint(equalTo: rawChipView.heightAnchor, constant: 6),
        ])

        ringView.translatesAutoresizingMaskIntoConstraints = false
        ringView.wantsLayer = true
        ringView.layer?.cornerRadius = Self.ringRadius
        ringView.layer?.borderWidth = 0
        root.addSubview(ringView)

        hoverRing.translatesAutoresizingMaskIntoConstraints = false
        hoverRing.wantsLayer = true
        hoverRing.layer?.cornerRadius = Self.cardRadius
        hoverRing.layer?.borderWidth = StripHoverLook.ringWidth
        hoverRing.layer?.opacity = 0
        root.addSubview(hoverRing)

        let ring = Self.ringWidth
        let pad = Self.capsulePadding
        NSLayoutConstraint.activate([
            imageBackground.topAnchor.constraint(equalTo: root.topAnchor, constant: ring),
            imageBackground.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: ring),
            imageBackground.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -ring),
            imageBackground.heightAnchor.constraint(equalTo: imageBackground.widthAnchor),

            ringView.topAnchor.constraint(equalTo: imageBackground.topAnchor, constant: -ring),
            ringView.bottomAnchor.constraint(equalTo: imageBackground.bottomAnchor, constant: ring),
            ringView.leadingAnchor.constraint(equalTo: imageBackground.leadingAnchor, constant: -ring),
            ringView.trailingAnchor.constraint(equalTo: imageBackground.trailingAnchor, constant: ring),

            hoverRing.topAnchor.constraint(equalTo: imageBackground.topAnchor),
            hoverRing.bottomAnchor.constraint(equalTo: imageBackground.bottomAnchor),
            hoverRing.leadingAnchor.constraint(equalTo: imageBackground.leadingAnchor),
            hoverRing.trailingAnchor.constraint(equalTo: imageBackground.trailingAnchor),
            hoverOverlay.topAnchor.constraint(equalTo: thumbnailView.topAnchor),
            hoverOverlay.bottomAnchor.constraint(equalTo: thumbnailView.bottomAnchor),
            hoverOverlay.leadingAnchor.constraint(equalTo: thumbnailView.leadingAnchor),
            hoverOverlay.trailingAnchor.constraint(equalTo: thumbnailView.trailingAnchor),

            thumbnailView.topAnchor.constraint(equalTo: imageBackground.topAnchor, constant: 4),
            thumbnailView.bottomAnchor.constraint(equalTo: imageBackground.bottomAnchor, constant: -4),
            thumbnailView.leadingAnchor.constraint(equalTo: imageBackground.leadingAnchor, constant: 4),
            thumbnailView.trailingAnchor.constraint(equalTo: imageBackground.trailingAnchor, constant: -4),

            failureStack.centerXAnchor.constraint(equalTo: imageBackground.centerXAnchor),
            failureStack.centerYAnchor.constraint(equalTo: imageBackground.centerYAnchor),
            failureStack.widthAnchor.constraint(lessThanOrEqualTo: imageBackground.widthAnchor, constant: -8),

            // The top-left slot is the flag's: the format badge
            // moves to the free bottom-right corner.
            formatBadge.bottomAnchor.constraint(equalTo: imageBackground.bottomAnchor, constant: -6),
            formatBadge.trailingAnchor.constraint(equalTo: imageBackground.trailingAnchor, constant: -6),

            flagView.topAnchor.constraint(equalTo: imageBackground.topAnchor, constant: 6),
            flagView.leadingAnchor.constraint(equalTo: imageBackground.leadingAnchor, constant: 6),
            badgeRow.topAnchor.constraint(equalTo: imageBackground.topAnchor, constant: 6),
            badgeRow.trailingAnchor.constraint(equalTo: imageBackground.trailingAnchor, constant: -6),
            badgeRow.heightAnchor.constraint(equalToConstant: 14),
            starsLabel.leadingAnchor.constraint(equalTo: imageBackground.leadingAnchor, constant: 6),
            starsLabel.bottomAnchor.constraint(equalTo: imageBackground.bottomAnchor, constant: -6),
            formatBadge.heightAnchor.constraint(equalToConstant: 14),
            formatBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),

            // Capsule: 18 pt high, 6 pt side padding, never wider than
            // the cell; the name truncates in the middle inside it.
            nameCapsule.topAnchor.constraint(equalTo: ringView.bottomAnchor, constant: 4),
            nameCapsule.heightAnchor.constraint(equalToConstant: Self.capsuleHeight),
            nameCapsule.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            nameCapsule.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor),
            nameCapsule.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            nameRow.centerYAnchor.constraint(equalTo: nameCapsule.centerYAnchor),
            nameRow.leadingAnchor.constraint(equalTo: nameCapsule.leadingAnchor, constant: pad),
            nameRow.trailingAnchor.constraint(equalTo: nameCapsule.trailingAnchor, constant: -pad),
        ])
    }

    /// Designated initializer. `NSCollectionView.register(_:forItemWithIdentifier:)`
    /// instantiates items through the Objective-C `initWithNibName:bundle:`
    /// path, and Swift does not inherit that initializer once a subclass
    /// declares its own designated `init()` — AppKit then hits the
    /// "unimplemented initializer" trap on the first cell. Overriding it
    /// here keeps both construction paths working.
    public override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        self.imageBackground = NSView()
        self.thumbnailView = NSImageView()
        self.nameLabel = NSTextField(labelWithString: "")
        self.formatBadge = NSTextField(labelWithString: "")
        super.init(nibName: nil, bundle: nil)
    }

    public convenience init() {
        self.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    public override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        thumbnailView.image = nil
        thumbnailView.layer?.removeAnimation(forKey: Self.fadeInKey)
        nameLabel.stringValue = ""
        applyBadges(ItemBadges())
        formatBadge.stringValue = ""
        formatBadge.isHidden = true
        currentItem = nil
        setFailed(false)
        setHovered(false, animated: false)
        updateSelectionAppearance()
    }

    public override var isSelected: Bool {
        didSet {
            updateSelectionAppearance()
            applyHover(animated: false)
        }
    }

    // MARK: - Hover

    func setHovered(_ on: Bool, animated: Bool = true) {
        guard on != isHovered else { return }
        isHovered = on
        applyHover(animated: animated)
    }

    /// A selected cell shows its selection ring and no hover.
    private var showsHover: Bool { isHovered && !isSelected }

    private func applyHover(animated: Bool) {
        guard isViewLoaded, let ring = hoverRing.layer, let veil = hoverOverlay.layer else { return }
        StripHoverLook.fade(ring, visible: showsHover, animated: animated)
        StripHoverLook.fade(veil, visible: showsHover, animated: animated)
    }

    /// Test seam: the name capsule's frame in the cell's own coordinates.
    var nameCapsuleFrameForTesting: NSRect {
        view.layoutSubtreeIfNeeded()
        return nameCapsule.frame
    }

    /// Test seam: what the hover draws now (target state).
    var hoverLookForTesting: (ringWidth: CGFloat, ringOpacity: Float, overlayAlpha: CGFloat) {
        let veil = hoverOverlay.layer
        let alpha = (veil?.opacity ?? 0) > 0 ? (veil?.backgroundColor?.alpha ?? 0) : 0
        return (hoverRing.layer?.borderWidth ?? 0, hoverRing.layer?.opacity ?? 0, alpha)
    }

    // MARK: - Configure

    public func configure(
        with item: BrowserItem,
        pixelSize: Int,
        cache: ThumbnailCache
    ) {
        currentItem = item
        nameLabel.stringValue = item.displayName
        applyBadges(item.badges)

        let bucket = BrowserFormatBucket.bucket(for: item.utType)
        // Show a format badge for non-JPEG common formats.
        if bucket != .jpeg && bucket != .other {
            formatBadge.stringValue = " \(bucket.displayName) "
            formatBadge.isHidden = false
        } else {
            formatBadge.isHidden = true
        }

        // Accessibility payload — filename + rating + flag.
        setFailed(false)
        view.setAccessibilityRole(.button)
        view.setAccessibilityValueDescription(item.displayName + PillMarks(item.badges).accessibilitySuffix)

        // Kick off the thumbnail decode. Cancellation happens in
        // `prepareForReuse` or `didEndDisplaying`.
        loadTask?.cancel()
        let source = item.imageSource
        loadTask = Task { [weak self] in
            do {
                let image = try await cache.thumbnail(for: source, maxPixelSize: pixelSize)
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    guard let self,
                          self.currentItem?.url == item.url else { return }
                    self.showThumbnail(image)
                }
            } catch is CancellationError {
                // Reused or scrolled away: not a failure.
            } catch {
                if Task.isCancelled { return }
                // Say so instead of a blank card.
                await MainActor.run { [weak self] in
                    guard let self, self.currentItem?.url == item.url else { return }
                    self.setFailed(true)
                }
            }
        }
    }

    /// Shows the decoded thumbnail with a fade: 80 ms,
    /// ease-out; at once under Reduce Motion.
    func showThumbnail(_ image: CGImage) {
        let size = NSSize(width: image.width, height: image.height)
        thumbnailView.image = NSImage(cgImage: image, size: size)
        guard !ReduceMotion.isOn, let layer = thumbnailView.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Self.fadeInDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: Self.fadeInKey)
    }

    /// Test seam: the thumbnail layer's fade-in, if one runs.
    var thumbnailFadeForTesting: CABasicAnimation? {
        thumbnailView.layer?.animation(forKey: Self.fadeInKey) as? CABasicAnimation
    }

    public func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
    }

    // MARK: - Badges

    /// The file this cell shows now (nil while in the reuse queue).
    var representedURL: URL? { currentItem?.url }

    /// New rating / flag / tags / edit mark for the file this cell shows,
    /// drawn in place: no reload, so the thumbnail, the selection and the
    /// first responder stay.
    func updateMarks(_ item: BrowserItem) {
        guard currentItem?.url == item.url else { return }
        currentItem = item
        applyBadges(item.badges)
    }

    /// Shows only set values: no empty stars, nothing for rating 0.
    func applyBadges(_ badges: ItemBadges) {
        flagView.isHidden = !badges.flagged
        starsLabel.stringValue = Badges.stars(badges.rating)
        starsLabel.isHidden = badges.rating <= 0
        rawChipView.isHidden = !badges.hasRAW
        rawChipButton.isHidden = !badges.hasRAW
        livePhotoView.isHidden = !badges.isLivePhoto
        pencilView.isHidden = !badges.edited
        let dots = Badges.dotColors(badges.tags).map { Badges.dotFill($0) }
        tagDotsView.image = Badges.tagDotsImage(dots)
        tagDotsView.isHidden = dots.isEmpty
    }

    @objc private func rawChipTapped(_ sender: Any?) { onRAWChip?() }

    /// Test seams: the clickable chip.
    var rawChipButtonForTesting: NSButton { rawChipButton }

    /// Test seam: what the cell shows now.
    var badgeStateForTesting: (flag: Bool, stars: String, raw: Bool, live: Bool, pencil: Bool, dots: Bool) {
        (!flagView.isHidden, starsLabel.isHidden ? "" : starsLabel.stringValue,
         !rawChipView.isHidden, !livePhotoView.isHidden, !pencilView.isHidden, !tagDotsView.isHidden)
    }

    // MARK: - Rating string

    public static func makeRatingString(rating: Int, flagged: Bool) -> String {
        let clamped = max(0, min(5, rating))
        // Only set values: no hollow stars.
        let stars = String(repeating: "★", count: clamped)
        if flagged { return stars.isEmpty ? "⚑" : stars + "  ⚑" }
        return stars
    }

    // MARK: - Decode failure

    private func setFailed(_ failed: Bool) {
        isFailed = failed
        failureStack.isHidden = !failed
        let name = currentItem?.displayName ?? ""
        view.setAccessibilityLabel(failed ? "\(name), can't preview" : name)
        updateToolTip()
        updateFailureLabel()
    }

    /// The failure text, else (filmstrip strip) the file name.
    private func updateToolTip() {
        guard isViewLoaded else { return }
        if isFailed {
            view.toolTip = "Shrike can't read this file."
        } else {
            view.toolTip = showsNameTooltip ? currentItem?.displayName : nil
        }
    }

    private func updateFailureLabel() {
        failureLabel.isHidden = !(isFailed && view.bounds.width >= Self.failureTextMinWidth)
    }

    // MARK: - Selection and live colours

    /// The colours of one look. Dynamic colours: resolved at draw time.
    struct Look: Equatable {
        var ring: NSColor?
        var capsule: NSColor?
        var text: NSColor
        var border: NSColor?
    }

    static func look(selected: Bool, windowIsKey: Bool, increaseContrast: Bool) -> Look {
        let border: NSColor? = increaseContrast ? .separatorColor : nil
        guard selected else { return Look(ring: nil, capsule: nil, text: .labelColor, border: border) }
        if windowIsKey {
            return Look(ring: .controlAccentColor, capsule: .selectedContentBackgroundColor,
                        text: .alternateSelectedControlTextColor, border: border)
        }
        return Look(ring: .unemphasizedSelectedContentBackgroundColor,
                    capsule: .unemphasizedSelectedContentBackgroundColor, text: .labelColor, border: border)
    }

    var currentLook: Look {
        Self.look(selected: isSelected,
                  windowIsKey: isKeyOverrideForTesting ?? (view.window?.isKeyWindow ?? false),
                  increaseContrast: ShrikeTokens.increaseContrast)
    }

    /// Selection change: flips visibility and asks for a redraw. The
    /// colours themselves are set in `applyColors()` (no I/O, one frame).
    private func updateSelectionAppearance() {
        nameCapsule.isHidden = !isSelected
        nameLabel.textColor = currentLook.text
        view.needsDisplay = true
    }

    /// Called from the root view's `updateLayer()`.
    private func applyColors() {
        colorPassesForTesting += 1
        let look = currentLook
        let appearance = view.effectiveAppearance
        imageBackground.layer?.backgroundColor = ShrikeTokens.surfaceSunken.resolvedCGColor(for: appearance)
        imageBackground.layer?.borderWidth = look.border == nil ? 0 : 1
        imageBackground.layer?.borderColor = look.border?.resolvedCGColor(for: appearance)
        ringView.layer?.borderWidth = look.ring == nil ? 0 : Self.ringWidth
        ringView.layer?.borderColor = look.ring?.resolvedCGColor(for: appearance)
        hoverRing.layer?.borderColor = StripHoverLook.ringColor(for: appearance)
        hoverRing.layer?.borderWidth = StripHoverLook.ringWidth
        nameCapsule.layer?.backgroundColor = look.capsule?.resolvedCGColor(for: appearance)
        nameLabel.textColor = look.text
    }

    /// Test seam: what the cell draws now (after a redraw).
    var drawnForTesting: (ring: CGColor?, ringWidth: CGFloat, capsule: CGColor?, capsuleShown: Bool,
                          card: CGColor?, cardBorder: CGFloat, text: NSColor?) {
        (ringView.layer?.borderColor, ringView.layer?.borderWidth ?? 0, nameCapsule.layer?.backgroundColor,
         !nameCapsule.isHidden, imageBackground.layer?.backgroundColor, imageBackground.layer?.borderWidth ?? 0,
         nameLabel.textColor)
    }

    /// Test seam: frames in the cell's coordinates.
    var geometryForTesting: (card: NSRect, ring: NSRect, capsule: NSRect) {
        (imageBackground.frame, ringView.frame, nameCapsule.frame)
    }

    var nameFontForTesting: NSFont? { nameLabel.font }
    /// Test seam: how many times the colours were set (`updateLayer`).
    private(set) var colorPassesForTesting = 0
    var failureShownForTesting: (icon: Bool, text: Bool) {
        (!failureStack.isHidden, !failureStack.isHidden && !failureLabel.isHidden)
    }
}

/// The cell's root view. Colours are set in `updateLayer()`.
@MainActor
final class ThumbnailCellView: NSView {
    var onUpdateLayer: (() -> Void)?
    var onLayout: (() -> Void)?

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() { onUpdateLayer?() }

    /// The pointing hand over a filmstrip-strip cell (spec 24 §2).
    override func resetCursorRects() {
        var ancestor = superview
        while let view = ancestor {
            if let collection = view as? BrowserCollectionView {
                if collection.hoverEnabled { addCursorRect(bounds, cursor: .pointingHand) }
                return
            }
            ancestor = view.superview
        }
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A decoration that never takes a click.
private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
