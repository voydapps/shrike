//
//  HistogramViews.swift
//  ShrikeUI
//
//  The viewer histogram:
//  the 320 × 180 overlay, the 248 × 96 inspector band, and the controller
//  that feeds both from `HistogramCalculator` off the main thread.
//
//  Main-thread budget: a request only cancels the previous task and
//  starts a new one (microseconds). The sample decode (≤ 1024 px, ImageIO
//  thumbnail path) and the vImage histogram run on a utility task, after
//  a 30 ms settle so fast navigation never decodes the images it skips.
//

import AppKit
import SwiftUI
import ImageIO
import ShrikeCore

// MARK: - Mode

/// `shrike.viewer.histogramMode`. The chip cycles in declaration order.
enum HistogramMode: String, CaseIterable, Sendable {
    case rgb, rgbl, l

    var chipTitle: String {
        switch self {
        case .rgb: return "RGB"
        case .rgbl: return "RGB + L"
        case .l: return "L"
        }
    }

    var next: HistogramMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    static var current: HistogramMode {
        get { HistogramMode(rawValue: Prefs.viewerHistogramMode) ?? .rgbl }
        set { Prefs.viewerHistogramMode = newValue.rawValue }
    }

    /// Channels drawn in this mode (for normalising).
    var channels: [HistogramData.Channel] {
        switch self {
        case .rgb: return [.red, .green, .blue]
        case .rgbl: return [.red, .green, .blue, .luminance]
        case .l: return [.luminance]
        }
    }
}

// MARK: - State

struct HistogramDisplayState: Equatable {
    /// Last histogram that landed (kept while a new one computes).
    var data: HistogramData?
    /// A newer image is on screen; `data` is from the previous one (40 %).
    var isStale = false
    /// The image could not be read: bins hidden, "No data".
    var noData = false
    var mode: HistogramMode = .rgbl
}

// MARK: - Geometry (pure, tested)

enum HistogramPlot {

    /// Clip marks show above this share of pixels (percent).
    static let clipThresholdPercent = 0.1

    /// The count that maps to the plot's full height: the highest bin
    /// among bins 1–254 of the drawn channels, so a spike at 0 or 255
    /// does not flatten the rest. Falls back to all bins when 1–254 are
    /// empty (a pure black-and-white image).
    static func scaleMax(_ data: HistogramData, mode: HistogramMode) -> UInt32 {
        var inner: UInt32 = 0
        var all: UInt32 = 0
        for channel in mode.channels {
            let bins = data.bins(channel)
            for i in 0..<bins.count {
                all = max(all, bins[i])
                if i >= 1 && i <= 254 { inner = max(inner, bins[i]) }
            }
        }
        return inner > 0 ? inner : all
    }

    /// `scaleMax` for one channel's bins (same 1–254 rule).
    static func scaleMax(_ bins: [UInt32]) -> UInt32 {
        var inner: UInt32 = 0, all: UInt32 = 0
        for i in 0..<bins.count {
            all = max(all, bins[i])
            if i >= 1 && i <= 254 { inner = max(inner, bins[i]) }
        }
        return inner > 0 ? inner : all
    }

    /// Bar heights 0…1 for one channel; taller bins clip at 1.
    static func heights(_ bins: [UInt32], scaleMax: UInt32) -> [CGFloat] {
        guard scaleMax > 0 else { return bins.map { _ in 0 } }
        return bins.map { min(1, CGFloat($0) / CGFloat(scaleMax)) }
    }

    static func showsShadowClip(_ data: HistogramData) -> Bool {
        data.anyChannelShadowsClippedPercent > clipThresholdPercent
    }

    static func showsHighlightClip(_ data: HistogramData) -> Bool {
        data.anyChannelHighlightsClippedPercent > clipThresholdPercent
    }

    /// VoiceOver value: "Shadows clipped 0.4 percent. Highlights
    /// clipped 2.1 percent. Average brightness 46 percent."
    static func accessibilityValue(_ state: HistogramDisplayState) -> String {
        if state.noData { return "No data" }
        guard let data = state.data else { return "Loading" }
        func one(_ v: Double) -> String { String(format: "%.1f", v) }
        return "Shadows clipped \(one(data.anyChannelShadowsClippedPercent)) percent. "
            + "Highlights clipped \(one(data.anyChannelHighlightsClippedPercent)) percent. "
            + "Average brightness \(Int(data.meanLuminancePercent.rounded())) percent."
    }
}

// MARK: - Plot view

/// Draws the bins, the clip marks and the "No data" state. The overlay
/// and the inspector band share it.
@MainActor
final class HistogramPlotView: NSView {

    var state = HistogramDisplayState() {
        didSet {
            guard state != oldValue else { return }
            alphaValue = state.isStale ? 0.4 : 1
            needsDisplay = true
            setAccessibilityValue(HistogramPlot.accessibilityValue(state))
        }
    }

    /// Inset of the plot inside this view (the overlay passes 0; its
    /// container already insets).
    var plotInset: CGFloat = 0

    /// Draw one channel alone, in its colour (the Levels panel's Red /
    /// Green / Blue view). nil = the `state.mode` drawing.
    var soloChannel: HistogramData.Channel? {
        didSet { if soloChannel != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Histogram")
        setAccessibilityValue(HistogramPlot.accessibilityValue(state))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    static let red = NSColor(srgbRed: 1, green: 0x45 / 255.0, blue: 0x3A / 255.0, alpha: 1)
    static let green = NSColor(srgbRed: 0x32 / 255.0, green: 0xD7 / 255.0, blue: 0x4B / 255.0, alpha: 1)
    static let blue = NSColor(srgbRed: 0x0A / 255.0, green: 0x84 / 255.0, blue: 1, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        let plot = bounds.insetBy(dx: plotInset, dy: plotInset)
        if state.noData {
            let text = NSAttributedString(string: "No data", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: plot.midX - size.width / 2, y: plot.midY - size.height / 2))
            return
        }
        guard let data = state.data, data.pixelCount > 0,
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = soloChannel.map { HistogramPlot.scaleMax(data.bins($0)) }
            ?? HistogramPlot.scaleMax(data, mode: state.mode)

        func path(_ channel: HistogramData.Channel) -> CGPath {
            let h = HistogramPlot.heights(data.bins(channel), scaleMax: scale)
            let p = CGMutablePath()
            let step = plot.width / CGFloat(max(1, h.count - 1))
            p.move(to: CGPoint(x: plot.minX, y: plot.minY))
            for (i, v) in h.enumerated() {
                p.addLine(to: CGPoint(x: plot.minX + CGFloat(i) * step, y: plot.minY + v * plot.height))
            }
            p.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
            p.closeSubpath()
            return p
        }

        ctx.saveGState()
        ctx.clip(to: plot)
        // Grid lines, white at 8 %.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        ctx.setLineWidth(1)
        for quarter in 1...3 {
            let x = (plot.minX + plot.width * CGFloat(quarter) / 4).rounded() + 0.5
            ctx.move(to: CGPoint(x: x, y: plot.minY))
            ctx.addLine(to: CGPoint(x: x, y: plot.maxY))
        }
        ctx.strokePath()
        if let solo = soloChannel {
            let color: NSColor = solo == .red ? Self.red : solo == .green ? Self.green
                : solo == .blue ? Self.blue : .white
            ctx.addPath(path(solo))
            ctx.setFillColor(color.withAlphaComponent(0.6).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            return
        }
        if state.mode != .l {
            // Overlaid channels, 45 % fill, screen blending: overlap reads white.
            ctx.setBlendMode(.screen)
            for (channel, color) in [(HistogramData.Channel.red, Self.red),
                                     (.green, Self.green), (.blue, Self.blue)] {
                ctx.addPath(path(channel))
                ctx.setFillColor(color.withAlphaComponent(0.45).cgColor)
                ctx.fillPath()
            }
            ctx.setBlendMode(.normal)
        }
        switch state.mode {
        case .rgbl:
            ctx.addPath(path(.luminance))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        case .l:
            ctx.addPath(path(.luminance))
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.6).cgColor)
            ctx.fillPath()
        case .rgb:
            break
        }
        ctx.restoreGState()

        // Clip marks: 6 pt white triangles at the plot's top corners.
        ctx.setFillColor(NSColor.white.cgColor)
        if HistogramPlot.showsShadowClip(data) {
            ctx.move(to: CGPoint(x: plot.minX, y: plot.maxY))
            ctx.addLine(to: CGPoint(x: plot.minX + 6, y: plot.maxY))
            ctx.addLine(to: CGPoint(x: plot.minX, y: plot.maxY - 6))
            ctx.closePath()
            ctx.fillPath()
        }
        if HistogramPlot.showsHighlightClip(data) {
            ctx.move(to: CGPoint(x: plot.maxX, y: plot.maxY))
            ctx.addLine(to: CGPoint(x: plot.maxX - 6, y: plot.maxY))
            ctx.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY - 6))
            ctx.closePath()
            ctx.fillPath()
        }
    }
}

// MARK: - Overlay (320 × 180)

@MainActor
final class HistogramOverlayView: HUDSurfaceView {

    // MARK: - Empty state

    /// True while the viewer shows its empty state: the view stays hidden
    /// whatever its own show / hide code asks for, and the asked-for state
    /// comes back when the empty state goes away.
    var isSuppressed = false {
        didSet { super.isHidden = wantsHidden || isSuppressed }
    }
    private var wantsHidden = false
    override var isHidden: Bool {
        get { super.isHidden }
        set { wantsHidden = newValue; super.isHidden = newValue || isSuppressed }
    }

    static let size = NSSize(width: 320, height: 180)

    let plotView = HistogramPlotView()
    let modeChip = NSButton(title: HistogramMode.rgbl.chipTitle, target: nil, action: nil)
    private let lowLabel = NSTextField(labelWithString: "0")
    private let highLabel = NSTextField(labelWithString: "255")

    /// The chip was clicked (the controller cycles and persists the mode).
    var onCycleMode: (() -> Void)?

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        setAccessibilityIdentifier("viewer.histogram")

        modeChip.isBordered = false
        modeChip.font = .systemFont(ofSize: 11, weight: .semibold)
        modeChip.contentTintColor = .labelColor
        modeChip.target = self
        modeChip.action = #selector(chipClicked(_:))
        modeChip.setAccessibilityLabel("Histogram mode")
        modeChip.toolTip = "Histogram mode"
        for label in [lowLabel, highLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
        }
        for view in [plotView, modeChip, lowLabel, highLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            modeChip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            modeChip.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            modeChip.heightAnchor.constraint(equalToConstant: 16),
            plotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            plotView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            plotView.topAnchor.constraint(equalTo: modeChip.bottomAnchor, constant: 4),
            plotView.bottomAnchor.constraint(equalTo: lowLabel.topAnchor, constant: -2),
            lowLabel.leadingAnchor.constraint(equalTo: plotView.leadingAnchor),
            lowLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            highLabel.trailingAnchor.constraint(equalTo: plotView.trailingAnchor),
            highLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ state: HistogramDisplayState) {
        plotView.state = state
        modeChip.title = state.mode.chipTitle
        lowLabel.isHidden = state.noData
        highLabel.isHidden = state.noData
    }

    /// Tests: what the plot draws.
    internal var stateForTesting: HistogramDisplayState { plotView.state }

    @objc private func chipClicked(_ sender: Any?) { onCycleMode?() }
}

// MARK: - Inspector band (248 × 96)

/// The inspector's Histogram section: the same plot, no chip, no axis.
struct HistogramBand: NSViewRepresentable {
    let state: HistogramDisplayState

    func makeNSView(context: Context) -> HistogramPlotView {
        let view = HistogramPlotView()
        view.state = state
        return view
    }

    func updateNSView(_ nsView: HistogramPlotView, context: Context) {
        nsView.state = state
    }
}

// MARK: - Controller

/// Computes histograms for whatever the viewer shows. Latest request
/// wins; nothing runs while no histogram is on screen (the source is kept
/// and computed when one appears).
@MainActor
final class HistogramController {

    enum Source {
        /// A displayed file: sampled from the file (≤ 1024 px), with the
        /// on-screen image as fallback.
        case file(URL?, CGImage)
        /// An edit-mode preview render.
        case image(CGImage)
    }

    static let settle: Duration = .milliseconds(30)
    static let editThrottle: Duration = .milliseconds(100)

    private(set) var state = HistogramDisplayState(mode: .current)
    /// Fires on every state change (overlay + inspector).
    var onChange: ((HistogramDisplayState) -> Void)?
    /// True while the overlay or the inspector shows the histogram.
    var isWanted: () -> Bool = { false }

    private let calculator = HistogramCalculator()
    private var task: Task<Void, Never>?
    private var pending: Source?
    private var editTimer: Task<Void, Never>?
    private var pendingEdit: CGImage?
    private var lastEditStart: ContinuousClock.Instant?
    /// Finished computations (tests).
    private(set) var completedCount = 0

    init() {}

    /// The file of the last `imageShown` (nil after `reset`).
    private(set) var lastShownURL: URL?

    /// The full image replaced a preview (or the file was redrawn).
    func imageShown(_ image: CGImage, url: URL?) {
        lastShownURL = url
        start(.file(url, image), settle: true)
    }

    /// A stand-in (preview / thumb) is on screen: keep the last
    /// histogram at 40 % until the new one lands.
    func markStale() {
        guard state.data != nil, !state.isStale else { return }
        update { $0.isStale = true }
    }

    /// The image could not be read.
    func showNoData() {
        task?.cancel()
        pending = nil
        update { $0.noData = true; $0.isStale = false; $0.data = nil }
    }

    /// Edit mode rendered a new preview: throttled to one computation
    /// per 100 ms, the newest render wins.
    func editImageRendered(_ image: CGImage) {
        pendingEdit = image
        guard editTimer == nil else { return }
        var wait = Duration.zero
        if let last = lastEditStart {
            let elapsed = ContinuousClock.now - last
            if elapsed < Self.editThrottle { wait = Self.editThrottle - elapsed }
        }
        editTimer = Task { @MainActor [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard let self, !Task.isCancelled else { return }
            self.editTimer = nil
            guard let image = self.pendingEdit else { return }
            self.pendingEdit = nil
            self.lastEditStart = .now
            self.start(.image(image), settle: false)
        }
    }

    /// The overlay or inspector appeared: compute what was deferred.
    func wantedDidChange() {
        guard isWanted(), let source = pending else { return }
        pending = nil
        start(source, settle: false)
    }

    func cycleMode() {
        let next = state.mode.next
        HistogramMode.current = next
        update { $0.mode = next }
    }

    /// The window closed: drop images and stop work.
    func reset() {
        lastShownURL = nil
        task?.cancel()
        editTimer?.cancel()
        editTimer = nil
        pending = nil
        pendingEdit = nil
        calculator.cancelAll()
    }

    /// Tests: waits for the task in flight.
    func waitForIdle() async {
        await editTimer?.value
        await task?.value
    }

    private func start(_ source: Source, settle: Bool) {
        task?.cancel()
        guard isWanted() else {
            pending = source
            return
        }
        pending = nil
        if state.data != nil { markStale() }
        let calculator = self.calculator
        let request = calculator.begin()   // in request order: the newest wins
        ShrikeSignposts.navigation.event("histogramRequest", "")
        task = Task { @MainActor [weak self] in
            if settle {
                try? await Task.sleep(for: Self.settle)
                if Task.isCancelled { return }
            }
            let result = await Task.detached(priority: .utility) { () -> HistogramData? in
                let sample: CGImage
                switch source {
                case .file(let url, let fallback):
                    sample = url.flatMap { Self.sample(url: $0) } ?? fallback
                case .image(let image):
                    sample = image
                }
                return await calculator.compute(from: sample, for: request)
            }.value
            guard let self, !Task.isCancelled, let result else { return }
            self.completedCount += 1
            self.update {
                $0.data = result.pixelCount > 0 ? result : nil
                $0.noData = result.pixelCount == 0
                $0.isStale = false
            }
        }
    }

    private func update(_ change: (inout HistogramDisplayState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        onChange?(next)
    }

    /// ≤ 1024 px copy of the file through the ImageIO thumbnail path
    /// (orientation applied; the decoded pixels are the sample's only).
    nonisolated static func sample(url: URL, maxEdge: Int = HistogramCalculator.defaultMaxSampleEdge) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
