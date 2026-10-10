//
//  InspectorPanel.swift
//  ShrikeUI
//
//  Right-side inspector panel. Content is SwiftUI in an NSHostingView:
//  it's a forms-like layout, a good fit for SwiftUI.
//
//  v1 scope: renders filename / dimensions / file size / color space / camera
//  block (read from the CGImage + URL). The Histogram band is the shared
//  `HistogramPlotView`.
//
//  A header row ("Inspector") carries the pin glyph at its
//  trailing end. The content scrolls below the header.
//

import AppKit
import SwiftUI
import CoreGraphics
import ImageIO
import ShrikeCore

@MainActor
final class InspectorPanel: HUDSurfaceView {

    /// Built the first time the panel shows: the
    /// full-screen inspector is hidden at launch, and its SwiftUI host
    /// cost layout time on every new viewer.
    private var hostingView: NSHostingView<InspectorContent>?
    /// Shared with the windowed inspector (one model, each
    /// host builds its own views).
    let viewModel: InspectorViewModel
    /// No header (EXIF) read until an inspector has been shown once
    /// (nothing extra on the first-pixel path).
    var headerReadsEnabled = false {
        didSet { if headerReadsEnabled && !oldValue { applyURL(pendingURL) } }
    }
    private var pendingURL: URL?

    override var isHidden: Bool {
        didSet {
            if !isHidden {
                installHostingViewIfNeeded()
                headerReadsEnabled = true
            }
        }
    }

    // Pin glyph moved to shared PinCornerOverlay at top-right.
    // The old LEFT-edge 20 pt pin strip is removed; its column is reclaimed
    // for content.
    private let pinOverlay: PinCornerOverlay

    /// Fired when the user clicks the pin glyph in fullscreen mode.
    var onTogglePin: (() -> Void)?

    private(set) var pinned: Bool = false

    /// The panel is as tall as its content
    /// (header + measured content), unless the host's top and bottom
    /// constraints leave less room (then the content scrolls). Weaker
    /// than the host's "bottom <= limit" constraint; before the first
    /// measurement it is huge, so the panel simply fills the room.
    static let unmeasuredHeight: CGFloat = 10_000
    private var preferredHeight: NSLayoutConstraint?
    /// Height wanted by the content, header included (nil: not measured).
    private(set) var measuredHeight: CGFloat?

    init() {
        let vm = InspectorViewModel()
        self.viewModel = vm
        self.pinOverlay = PinCornerOverlay(
            identifierSuffix: "inspector",
            panelName: "Inspector",
            appearance: .fullscreenHUD
        )

        super.init(frame: .zero)
        wantsLayer = true

        setupPinOverlay()
        vm.actions = InspectorActions(
            rate: { [weak self] in self?.onRate?($0) },
            toggleFlag: { [weak self] in self?.onToggleFlag?() },
            removeTag: { [weak self] in self?.onRemoveTag?($0) },
            addTag: { [weak self] in
                guard let self else { return }
                self.onAddTag?(self.viewModel.tagsAnchor ?? self)
            },
            revert: { [weak self] in self?.onRevert?() }
        )
        let preferred = heightAnchor.constraint(equalToConstant: Self.unmeasuredHeight)
        preferred.priority = NSLayoutConstraint.Priority(250)
        preferred.isActive = true
        preferredHeight = preferred
        vm.onContentHeight = { [weak self] height in
            // Called inside a SwiftUI update: change the constraint on
            // the next main-queue turn, never inside the layout pass.
            Task { @MainActor [weak self] in self?.applyContentHeight(height) }
        }
    }

    /// Test seam and the real path: set the wanted height from a measured
    /// content height.
    func applyContentHeight(_ height: CGFloat) {
        guard height > 0 else { return }
        let total = (Self.headerHeight + height).rounded(.up)
        measuredHeight = total
        if preferredHeight?.constant != total { preferredHeight?.constant = total }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Header row: the title and, at its trailing end,
    /// the pin glyph.
    static let headerHeight: CGFloat = 36
    private let headerRow = NSView()
    private let headerTitle = NSTextField(labelWithString: "Inspector")

    private func setupPinOverlay() {
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.appearance = NSAppearance(named: .darkAqua)
        addSubview(headerRow)
        headerTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        headerTitle.textColor = .secondaryLabelColor
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.setAccessibilityRole(.staticText)
        headerRow.addSubview(headerTitle)
        pinOverlay.translatesAutoresizingMaskIntoConstraints = false
        pinOverlay.delegate = self
        headerRow.addSubview(pinOverlay)
        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: topAnchor),
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerRow.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            headerTitle.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: 16),
            headerTitle.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            headerTitle.trailingAnchor.constraint(lessThanOrEqualTo: pinOverlay.leadingAnchor, constant: -8),
            pinOverlay.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor, constant: -8),
            pinOverlay.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            pinOverlay.widthAnchor.constraint(equalToConstant: PinCornerOverlay.hitSize),
            pinOverlay.heightAnchor.constraint(equalToConstant: PinCornerOverlay.hitSize),
        ])
    }

    @discardableResult
    private func installHostingViewIfNeeded() -> NSHostingView<InspectorContent> {
        if let hostingView { return hostingView }
        let hostingView = NSHostingView(rootView: InspectorContent(model: viewModel))
        self.hostingView = hostingView
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.sizingOptions = []
        addSubview(hostingView, positioned: .below, relativeTo: headerRow)

        // The content sits below the header row.
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: headerRow.bottomAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        return hostingView
    }

    /// Test seam — the header row's frame in panel coordinates.
    internal var headerFrameForTesting: NSRect { layoutSubtreeIfNeeded(); return headerRow.frame }

    func setPinned(_ flag: Bool) {
        pinned = flag
        pinOverlay.setPinned(flag)
    }

    // Called by ViewerContentView when a new image becomes current.
    // MARK: - Actions (Culling and Edits rows)

    /// A star was clicked (0 = the "Clear" link).
    var onRate: ((Int) -> Void)?
    /// The Flag checkbox was clicked.
    var onToggleFlag: (() -> Void)?
    /// A tag chip's ⓧ.
    var onRemoveTag: ((String) -> Void)?
    /// The "+" chip: open the Tags popover on the Tags row.
    var onAddTag: ((NSView) -> Void)?
    /// "Revert to Original…".
    var onRevert: (() -> Void)?

    // Called by ViewerContentView when a new image becomes current.
    func updatePlaceholder(index: Int, total: Int, image: CGImage) {
        viewModel.indexSummary = "\(index + 1) of \(total)"
    }

    /// The displayed file changed: File rows at once, then the header
    /// (`PhotoInfo`, off the main thread; the newest file wins).
    func updateForURL(_ url: URL?) {
        pendingURL = url
        guard headerReadsEnabled else { return }
        applyURL(url)
    }

    private func applyURL(_ url: URL?) {
        guard url != viewModel.url else { return }
        viewModel.url = url
        viewModel.originalKeptSince = nil
        infoTask?.cancel()
        guard let url else {
            viewModel.facts = InspectorFacts()
            return
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
        viewModel.facts = InspectorRows.facts(url: url, fileSize: size, info: nil)
        infoTask = Task { [weak self] in
            let info = try? await PhotoInfo.read(url)
            guard !Task.isCancelled, let self, self.viewModel.url == url else { return }
            self.viewModel.facts = InspectorRows.facts(url: url, fileSize: size, info: info)
        }
    }

    /// "Also: DSC_0042.ORF (24.1 MB)" under the name, for groups.
    func updateAlsoLine(_ line: String?) {
        if viewModel.alsoLine != line { viewModel.alsoLine = line }
    }

    /// Rating, flag, tags and the edited state of the displayed item.
    /// Histogram band (248 × 96).
    func updateHistogram(_ state: HistogramDisplayState) {
        if viewModel.histogram != state { viewModel.histogram = state }
    }

    func updateMarks(_ marks: PillMarks) {
        if viewModel.marks != marks { viewModel.marks = marks }
    }

    /// When the displayed file has a Shrike edit: the date of the kept
    /// original ("Original kept since 25 Sep 2026"); nil hides the row.
    func updateOriginalDate(_ date: Date?) {
        viewModel.originalKeptSince = date.map { InspectorRows.originalKept(since: $0) }
    }

    private var infoTask: Task<Void, Never>?

    // MARK: - Test seams

    /// Replacement — exposes the corner overlay so overlap
    /// tests can assert its top-right placement and that it doesn't
    /// overlap the content bounds (rounded rect, 20×20 at 8 pt inset).
    var pinOverlayForTesting: PinCornerOverlay { pinOverlay }

    /// Current pin state mirror.
    var pinOverlayPinnedForTesting: Bool { pinOverlay.isPinnedForTesting }

    /// Exposes the content hosting view for overlap assertions (builds
    /// it if the panel has not shown yet).
    var contentViewForTesting: NSView { installHostingViewIfNeeded() }

    /// The SwiftUI host exists (it is built on the first show).
    var hostingViewBuiltForTesting: Bool { hostingView != nil }

    /// The rows on screen (tests).
    var modelForTesting: InspectorViewModel { viewModel }

    /// Waits for the header read of the current file (tests).
    func waitForInfo() async { await infoTask?.value }
}

// MARK: - PinCornerOverlayDelegate

extension InspectorPanel: PinCornerOverlayDelegate {
    func pinCornerOverlayDidToggle(_ overlay: PinCornerOverlay) {
        onTogglePin?()
    }
}

// MARK: - SwiftUI content

@MainActor
final class InspectorViewModel: ObservableObject {
    @Published var url: URL?
    @Published var indexSummary: String = ""
    @Published var alsoLine: String?
    @Published var facts = InspectorFacts()
    @Published var marks = PillMarks()
    @Published var originalKeptSince: String?
    @Published var histogram = HistogramDisplayState()

    /// Height of the scrolled content (padding included), reported by the
    /// SwiftUI content after every layout. Not `@Published`: it feeds an
    /// AppKit constraint, never a SwiftUI update.
    var contentHeight: CGFloat = 0
    var onContentHeight: ((CGFloat) -> Void)?

    /// The Tags row's AppKit view (the popover anchors on it).
    weak var tagsAnchor: NSView?
    var actions = InspectorActions()
}

/// Closures the SwiftUI rows call; set by `InspectorPanel`.
@MainActor
struct InspectorActions {
    var rate: (Int) -> Void = { _ in }
    var toggleFlag: () -> Void = {}
    var removeTag: (String) -> Void = { _ in }
    var addTag: () -> Void = {}
    var revert: () -> Void = {}
}

struct InspectorContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct InspectorContent: View {
    @ObservedObject var model: InspectorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let url = model.url {
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if let also = model.alsoLine {
                        Text(also)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if !model.indexSummary.isEmpty {
                    Text(model.indexSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                section("File", rows: model.facts.file.filter { $0.label != "Name" })
                if !model.facts.capture.isEmpty {
                    section("Capture", rows: model.facts.capture)
                }
                if let location = model.facts.location {
                    section("Location", rows: [InspectorRow("", location)])
                    if let coordinate = model.facts.coordinate, let url = model.url {
                        Button(ShowInMaps.linkTitle) { ShowInMaps.open(coordinate, file: url) }
                            .buttonStyle(.link)
                            .controlSize(.small)
                    }
                }
                if model.url != nil {
                    cullingSection
                }
                if model.marks.edited, let since = model.originalKeptSince {
                    VStack(alignment: .leading, spacing: 6) {
                        header("Edits")
                        Text(since)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button("Revert to Original…") { model.actions.revert() }
                            .controlSize(.small)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    header("Histogram")
                    // As wide as the column (248 pt at the
                    // 280 pt default); a fixed 248 made the content 280 pt
                    // wide, so a narrower column clipped it on the left.
                    HistogramBand(state: model.histogram)
                        .frame(maxWidth: .infinity)
                        .frame(height: 96)
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: InspectorContentHeightKey.self, value: proxy.size.height)
            })
        }
        .onPreferenceChange(InspectorContentHeightKey.self) { height in
            model.contentHeight = height
            model.onContentHeight?(height)
        }
        .tint(Color(nsColor: .controlAccentColor))
        .frame(minWidth: ViewerSplitController.inspectorMinimumWidth, idealWidth: 280)
        .background(Color.clear)
    }

    private var cullingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            header("Culling")
            HStack(spacing: 3) {
                ForEach(1...5, id: \.self) { i in
                    let filled = model.marks.rating >= i
                    Button { model.actions.rate(i) } label: {
                        Image(systemName: filled ? "star.fill" : "star")
                            .font(.system(size: 14))
                            .foregroundStyle(filled ? Color(nsColor: .controlAccentColor) : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rate \(i) star\(i == 1 ? "" : "s")")
                }
                if model.marks.rating > 0 {
                    Button("Clear") { model.actions.rate(0) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .padding(.leading, 6)
                }
            }
            Toggle("Flag", isOn: Binding(get: { model.marks.flagged },
                                         set: { _ in model.actions.toggleFlag() }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            HStack(spacing: 4) {
                ForEach(model.marks.tags, id: \.name) { tag in
                    HStack(spacing: 3) {
                        Text(tag.name).font(.system(size: 11))
                        Button { model.actions.removeTag(tag.name) } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove tag \(tag.name)")
                    }
                    .padding(.leading, 7).padding(.trailing, 4).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.2)))
                }
                Button { model.actions.addTag() } label: {
                    Image(systemName: "plus").font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add tag")
            }
            .background(TagsAnchorReporter(model: model))
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private func section(_ title: String, rows: [InspectorRow]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header(title)
            ForEach(rows) { r in
                HStack(alignment: .firstTextBaseline) {
                    if !r.label.isEmpty {
                        Text(r.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                    }
                    if r.label == "Folder", let folder = model.url?.deletingLastPathComponent() {
                        // Click reveals the file in Finder.
                        // Not drawn as a link, `labelColor`.
                        Button(r.value) {
                            NSWorkspace.shared.activateFileViewerSelecting([model.url ?? folder])
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    } else {
                        Text(r.value)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary)
                            .lineLimit(r.label.isEmpty ? 3 : 1)
                            .truncationMode(.middle)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

/// Hands the Tags row's AppKit view to the model (popover anchor).
private struct TagsAnchorReporter: NSViewRepresentable {
    let model: InspectorViewModel
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        model.tagsAnchor = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
