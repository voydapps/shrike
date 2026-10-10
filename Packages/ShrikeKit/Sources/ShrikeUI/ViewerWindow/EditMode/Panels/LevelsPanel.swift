//
//  LevelsPanel.swift
//  ShrikeUI
//
//  The Levels tool panel.
//
//   Levels                                        280 pt panel, 248 pt content
//   Channel  [RGB ▾]                              RGB · Red · Green · Blue
//   ┌──────────────── 248 × 96 ────────────┐      the channel's histogram
//   ▲────────────────◆─────────────────△          input black / gamma / white
//   [  0 ]         [1.00]          [255]          fields 48 pt
//   Output
//   ▲─────────────────────────────────△
//   [  0 ]                          [255]
//                                                 12 pt
//   [   Auto Contrast   ] [    Auto Color    ]    120 pt each, 8 pt gap
//   Already full range. Nothing to change.        status, 11 pt, 16 pt tall
//                                       [Reset]   trailing
//
//  Each channel keeps its own five values; the panel holds the whole
//  `LevelsParams` and shows one channel. Every handle is its own view: it
//  takes keyboard focus (←/→ ±1, ⇧ ±10; gamma ±0.01 / ±0.10) and is a
//  VoiceOver slider with its own label.
//
//  Writes (through the colour panel's coalescer):
//    * a drag frame  → `onParamsChanged` (draft render),
//    * drag end, a field commit, Reset → `onEditEnded` (one undo step),
//    * an arrow key  → `onParamsCommitted` (full render; quick presses
//      share one step through the controller's 500 ms idle),
//    * Auto Contrast / Auto Color → `onAuto` (the controller reads the
//      input histogram and writes, or reports "nothing to change").
//

import AppKit
import ShrikeCore
import ShrikeEdit

// MARK: - Channel and handle

/// The channel the panel shows (the popup).
enum LevelsPanelChannel: Int, CaseIterable, Sendable {
    case rgb, red, green, blue

    var title: String {
        switch self {
        case .rgb: return "RGB"
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        }
    }

    /// The histogram channel drawn alone; nil = RGB overlaid.
    var soloHistogramChannel: HistogramData.Channel? {
        switch self {
        case .rgb: return nil
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        }
    }
}

extension LevelsParams {
    /// One channel's handles, by the panel's channel.
    subscript(channel: LevelsPanelChannel) -> LevelsChannel {
        get {
            switch channel {
            case .rgb: return master
            case .red: return red
            case .green: return green
            case .blue: return blue
            }
        }
        set {
            switch channel {
            case .rgb: master = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }
}

/// The five handles.
enum LevelsHandleKind: Int, CaseIterable, Sendable {
    case inBlack, gamma, inWhite, outBlack, outWhite

    /// VoiceOver label.
    var accessibilityLabel: String {
        switch self {
        case .inBlack: return "Input black point"
        case .gamma: return "Midtones"
        case .inWhite: return "Input white point"
        case .outBlack: return "Output black point"
        case .outWhite: return "Output white point"
        }
    }

    var isInput: Bool { self == .inBlack || self == .gamma || self == .inWhite }

    /// One arrow-key step; ⇧ gives the big step.
    func step(big: Bool) -> Double {
        if self == .gamma { return big ? 0.10 : 0.01 }
        return big ? 10 : 1
    }
}

/// The one-line status under the autos.
enum LevelsStatus {
    static let contrastApplied = "Auto Contrast applied to RGB."
    static let colorApplied = "Auto Color applied to Red, Green and Blue."
    static let alreadyFullRange = "Already full range. Nothing to change."
    static let alreadyApplied = "Already applied. Nothing to change."

    static func applied(_ kind: LevelsAutoKind) -> String {
        kind == .contrast ? contrastApplied : colorApplied
    }
}

// MARK: - Pure rules (tested)

enum LevelsRules {

    /// `channel` with `kind` set to `value`, clamped to the valid ranges:
    /// input black 0 … white − 2, input white black + 2 … 255, gamma
    /// 0.10 … 9.99 (2 decimals), output 0 … 255 each.
    static func setting(_ kind: LevelsHandleKind, to value: Double, in channel: LevelsChannel) -> LevelsChannel {
        var c = channel
        guard value.isFinite else { return c }
        switch kind {
        case .inBlack:
            let v = Int(value.rounded())
            c.inBlack = UInt8(clamping: min(max(v, 0), Int(c.inWhite) - 2))
        case .inWhite:
            let v = Int(value.rounded())
            c.inWhite = UInt8(clamping: min(max(v, Int(c.inBlack) + 2), 255))
        case .gamma:
            let range = LevelsChannel.gammaRange
            c.gamma = (min(max(value, range.lowerBound), range.upperBound) * 100).rounded() / 100
        case .outBlack:
            c.outBlack = UInt8(clamping: min(max(Int(value.rounded()), 0), 255))
        case .outWhite:
            c.outWhite = UInt8(clamping: min(max(Int(value.rounded()), 0), 255))
        }
        return c
    }

    static func value(_ kind: LevelsHandleKind, of c: LevelsChannel) -> Double {
        switch kind {
        case .inBlack: return Double(c.inBlack)
        case .gamma: return c.gamma
        case .inWhite: return Double(c.inWhite)
        case .outBlack: return Double(c.outBlack)
        case .outWhite: return Double(c.outWhite)
        }
    }

    /// The handle's place on its track, 0…1. The midtones handle sits
    /// where the input grey maps to 50 % output: `black + (white − black)
    /// · 0.5^gamma` (gamma 1 = halfway; > 1 brightens, handle moves left).
    static func position(_ kind: LevelsHandleKind, of c: LevelsChannel) -> Double {
        switch kind {
        case .gamma:
            let b = Double(c.inBlack), w = Double(c.inWhite)
            return (b + (w - b) * pow(0.5, c.gamma)) / 255
        default:
            return value(kind, of: c) / 255
        }
    }

    /// The value a handle dragged to `t` (0…1 along its track) takes.
    static func value(_ kind: LevelsHandleKind, at t: Double, in c: LevelsChannel) -> Double {
        let level = min(max(t, 0), 1) * 255
        guard kind == .gamma else { return level }
        let b = Double(c.inBlack), w = Double(c.inWhite)
        let fraction = min(max((level - b) / max(w - b, 1), 0.0005), 0.9995)
        return log(fraction) / log(0.5)
    }

    /// Text a field shows: gamma with 2 decimals, the rest as integers.
    static func text(_ kind: LevelsHandleKind, of c: LevelsChannel) -> String {
        kind == .gamma ? String(format: "%.2f", c.gamma) : String(Int(value(kind, of: c)))
    }
}

// MARK: - Handle view

/// One draggable, focusable handle: ▲ black, ◆ midtones, △ white.
@MainActor
final class LevelsHandleView: NSView {

    let kind: LevelsHandleKind
    /// Drag to `x` in the track's coordinates; `ended` on mouse up.
    var onDrag: ((LevelsHandleKind, CGFloat, Bool) -> Void)?
    /// Arrow key or VoiceOver step: direction ±1, `big` with ⇧.
    var onStep: ((LevelsHandleKind, Double, Bool) -> Void)?
    /// VoiceOver increment / decrement (value up / down).
    var onAccessibilityStep: ((LevelsHandleKind, Double) -> Void)?

    static let size = NSSize(width: 14, height: 12)

    init(kind: LevelsHandleKind) {
        self.kind = kind
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(kind.accessibilityLabel)
        setAccessibilityIdentifier("levels.handle.\(kind)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var isFlipped: Bool { false }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { shapePath().fill() }

    private func shapePath() -> NSBezierPath {
        let b = bounds.insetBy(dx: 1, dy: 1)
        let p = NSBezierPath()
        if kind == .gamma {
            p.move(to: NSPoint(x: b.midX, y: b.maxY))
            p.line(to: NSPoint(x: b.maxX - 1.5, y: b.midY))
            p.line(to: NSPoint(x: b.midX, y: b.minY))
            p.line(to: NSPoint(x: b.minX + 1.5, y: b.midY))
        } else {
            // Points up at the track above it.
            p.move(to: NSPoint(x: b.midX, y: b.maxY))
            p.line(to: NSPoint(x: b.maxX, y: b.minY))
            p.line(to: NSPoint(x: b.minX, y: b.minY))
        }
        p.close()
        return p
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = shapePath()
        switch kind {
        case .inBlack, .outBlack:
            NSColor.black.setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.6).setStroke()
        case .gamma:
            NSColor.gray.setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.6).setStroke()
        case .inWhite, .outWhite:
            NSColor.white.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.6).setStroke()
        }
        path.lineWidth = 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        drag(event, ended: false)
    }

    override func mouseDragged(with event: NSEvent) { drag(event, ended: false) }
    override func mouseUp(with event: NSEvent) { drag(event, ended: true) }

    private func drag(_ event: NSEvent, ended: Bool) {
        guard let track = superview else { return }
        let x = track.convert(event.locationInWindow, from: nil).x
        onDrag?(kind, x, ended)
    }

    override func keyDown(with event: NSEvent) {
        let big = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123: onStep?(kind, -1, big)   // ←
        case 124: onStep?(kind, 1, big)    // →
        case 125: onAccessibilityStep?(kind, big ? -10 : -1)   // ↓: value down
        case 126: onAccessibilityStep?(kind, big ? 10 : 1)     // ↑: value up
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool {
        onAccessibilityStep?(kind, 1)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        onAccessibilityStep?(kind, -1)
        return true
    }
}

// MARK: - Track

/// A 248 pt track with a grey ramp and its handles below it.
@MainActor
final class LevelsTrackView: NSView {

    let handles: [LevelsHandleView]
    /// Handle places, 0…1, by kind.
    var positions: [LevelsHandleKind: Double] = [:] { didSet { needsLayout = true } }

    /// Half a handle: the ramp's ends sit where a handle centre can go.
    static let inset: CGFloat = LevelsHandleView.size.width / 2
    static let height: CGFloat = 18

    init(kinds: [LevelsHandleKind]) {
        handles = kinds.map(LevelsHandleView.init(kind:))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for h in handles { addSubview(h) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    /// Track x for a place `t` (0…1), and back.
    func x(for t: Double) -> CGFloat {
        Self.inset + CGFloat(min(max(t, 0), 1)) * max(bounds.width - 2 * Self.inset, 1)
    }

    func t(for x: CGFloat) -> Double {
        Double((x - Self.inset) / max(bounds.width - 2 * Self.inset, 1))
    }

    override func layout() {
        super.layout()
        let size = LevelsHandleView.size
        for h in handles {
            let t = positions[h.kind] ?? 0
            h.frame = NSRect(x: x(for: t) - size.width / 2, y: 0, width: size.width, height: size.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let ramp = NSRect(x: Self.inset, y: LevelsHandleView.size.height + 1,
                          width: max(bounds.width - 2 * Self.inset, 1), height: 4)
        NSGradient(starting: .black, ending: .white)?.draw(in: ramp, angle: 0)
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: ramp).stroke()
    }
}

// MARK: - Panel

@MainActor
final class LevelsPanel: NSView, NSTextFieldDelegate {

    // MARK: Hooks

    /// A drag frame (draft render).
    var onParamsChanged: ((LevelsParams) -> Void)?
    /// An arrow-key step (full render; the controller's idle joins quick
    /// presses into one undo step).
    var onParamsCommitted: ((LevelsParams) -> Void)?
    /// Drag end, a field commit or Reset: one undo step.
    var onEditEnded: ((LevelsParams) -> Void)?
    /// Auto Contrast / Auto Color was pressed.
    var onAuto: ((LevelsAutoKind) -> Void)?

    // MARK: State

    private(set) var params = LevelsParams.identity
    private(set) var channel: LevelsPanelChannel = .rgb

    static let contentWidth: CGFloat = 248
    static let fieldWidth: CGFloat = 48
    static let autoButtonWidth: CGFloat = 120
    static let statusHeight: CGFloat = 16

    // MARK: Views

    private let titleLabel = NSTextField(labelWithString: "Levels")
    private let channelLabel = NSTextField(labelWithString: "Channel")
    private let channelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let histogramView = HistogramPlotView(frame: .zero)
    private let inputTrack = LevelsTrackView(kinds: [.inBlack, .gamma, .inWhite])
    private let outputLabel = NSTextField(labelWithString: "Output")
    private let outputTrack = LevelsTrackView(kinds: [.outBlack, .outWhite])
    private var fields: [LevelsHandleKind: NSTextField] = [:]
    private let autoContrastButton = NSButton(title: "Auto Contrast", target: nil, action: nil)
    private let autoColorButton = NSButton(title: "Auto Color", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)

    private var flagsMonitor: Any?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        refreshAll()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Build

    private func build() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        channelLabel.font = .systemFont(ofSize: 12)
        outputLabel.font = .systemFont(ofSize: 12)

        for c in LevelsPanelChannel.allCases { channelPopup.addItem(withTitle: c.title) }
        channelPopup.target = self
        channelPopup.action = #selector(channelPicked(_:))
        channelPopup.setAccessibilityLabel("Channel")
        channelPopup.setAccessibilityIdentifier("levels.channel")

        histogramView.wantsLayer = true
        histogramView.layer?.cornerRadius = 4
        histogramView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        histogramView.plotInset = 2
        histogramView.state = HistogramDisplayState(mode: .rgb)
        histogramView.setAccessibilityLabel("Levels histogram")
        histogramView.translatesAutoresizingMaskIntoConstraints = false

        for track in [inputTrack, outputTrack] {
            for h in track.handles {
                h.onDrag = { [weak self, weak track] kind, x, ended in
                    guard let self, let track else { return }
                    self.dragHandle(kind, toTrackX: x, on: track, ended: ended)
                }
                h.onStep = { [weak self] kind, direction, big in
                    self?.stepHandle(kind, direction: direction, big: big, visual: true)
                }
                h.onAccessibilityStep = { [weak self] kind, amount in
                    self?.stepHandle(kind, direction: amount, big: false, visual: false)
                }
            }
        }

        for kind in LevelsHandleKind.allCases {
            let f = NSTextField(string: "")
            f.translatesAutoresizingMaskIntoConstraints = false
            f.alignment = .center
            f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            f.controlSize = .small
            f.target = self
            f.action = #selector(fieldCommitted(_:))
            f.delegate = self
            f.setAccessibilityLabel(kind.accessibilityLabel)
            f.setAccessibilityIdentifier("levels.field.\(kind)")
            f.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
            fields[kind] = f
        }

        for b in [autoContrastButton, autoColorButton, resetButton] {
            b.bezelStyle = .push
            b.controlSize = .regular
            b.font = .systemFont(ofSize: 13)
            b.target = self
            b.translatesAutoresizingMaskIntoConstraints = false
        }
        autoContrastButton.action = #selector(autoContrastPressed(_:))
        autoColorButton.action = #selector(autoColorPressed(_:))
        resetButton.action = #selector(resetPressed(_:))
        autoContrastButton.widthAnchor.constraint(equalToConstant: Self.autoButtonWidth).isActive = true
        autoColorButton.widthAnchor.constraint(equalToConstant: Self.autoButtonWidth).isActive = true
        // Tooltips from the live table: "Auto Contrast  ·  ⌥⇧⌘L".
        LiveTooltips.shared.bind(autoContrastButton, command: .autoContrast, context: .viewer)
        LiveTooltips.shared.bind(autoColorButton, command: .autoColor, context: .viewer)
        resetButton.toolTip = "Reset All Channels"
        autoContrastButton.setAccessibilityHelp("Stretches brightness and contrast. Keeps the colors in balance.")
        autoColorButton.setAccessibilityHelp("Stretches each color on its own. Removes a color tint.")
        resetButton.setAccessibilityHelp("Sets all channels back to no change.")
        autoContrastButton.setAccessibilityIdentifier("levels.autoContrast")
        autoColorButton.setAccessibilityIdentifier("levels.autoColor")
        resetButton.setAccessibilityIdentifier("levels.reset")

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setAccessibilityIdentifier("levels.status")

        let channelRow = NSStackView(views: [channelLabel, channelPopup])
        channelRow.orientation = .horizontal
        channelRow.spacing = 8

        let inputFields = fieldRow([.inBlack, .gamma, .inWhite])
        let outputFields = fieldRow([.outBlack, .outWhite])

        let autoRow = NSStackView(views: [autoContrastButton, autoColorButton])
        autoRow.orientation = .horizontal
        autoRow.spacing = 8

        let resetRow = NSView()
        resetRow.translatesAutoresizingMaskIntoConstraints = false
        resetRow.addSubview(resetButton)

        let stack = NSStackView(views: [
            titleLabel, channelRow, histogramView, inputTrack, inputFields,
            outputLabel, outputTrack, outputFields, autoRow, statusLabel, resetRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(10, after: titleLabel)
        stack.setCustomSpacing(10, after: channelRow)
        stack.setCustomSpacing(4, after: histogramView)
        stack.setCustomSpacing(2, after: inputTrack)
        stack.setCustomSpacing(10, after: inputFields)
        stack.setCustomSpacing(2, after: outputTrack)
        // 12 pt before the autos.
        stack.setCustomSpacing(12, after: outputFields)
        stack.setCustomSpacing(4, after: autoRow)
        stack.setCustomSpacing(4, after: statusLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let w = Self.contentWidth
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
            histogramView.widthAnchor.constraint(equalToConstant: w),
            histogramView.heightAnchor.constraint(equalToConstant: 96),
            inputTrack.widthAnchor.constraint(equalToConstant: w),
            inputTrack.heightAnchor.constraint(equalToConstant: LevelsTrackView.height),
            outputTrack.widthAnchor.constraint(equalToConstant: w),
            outputTrack.heightAnchor.constraint(equalToConstant: LevelsTrackView.height),
            inputFields.widthAnchor.constraint(equalToConstant: w),
            outputFields.widthAnchor.constraint(equalToConstant: w),
            // The status line keeps its 16 pt when empty (nothing moves).
            statusLabel.widthAnchor.constraint(equalToConstant: w),
            statusLabel.heightAnchor.constraint(equalToConstant: Self.statusHeight),
            resetRow.widthAnchor.constraint(equalToConstant: w),
            resetRow.heightAnchor.constraint(equalTo: resetButton.heightAnchor),
            resetButton.topAnchor.constraint(equalTo: resetRow.topAnchor),
            resetButton.trailingAnchor.constraint(equalTo: resetRow.trailingAnchor),
        ])
        buildKeyViewLoop()
    }

    /// Fields under a track: first leading, last trailing, a middle one
    /// centred.
    private func fieldRow(_ kinds: [LevelsHandleKind]) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        var constraints: [NSLayoutConstraint] = []
        for (i, kind) in kinds.enumerated() {
            guard let f = fields[kind] else { continue }
            row.addSubview(f)
            constraints.append(f.topAnchor.constraint(equalTo: row.topAnchor))
            constraints.append(f.bottomAnchor.constraint(equalTo: row.bottomAnchor))
            if i == 0 {
                constraints.append(f.leadingAnchor.constraint(equalTo: row.leadingAnchor))
            } else if i == kinds.count - 1 {
                constraints.append(f.trailingAnchor.constraint(equalTo: row.trailingAnchor))
            } else {
                constraints.append(f.centerXAnchor.constraint(equalTo: row.centerXAnchor))
            }
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    /// Tab order: popup → input handles → input fields → output
    /// handles → output fields → Auto Contrast → Auto Color → Reset.
    private func buildKeyViewLoop() {
        var chain: [NSView] = [channelPopup]
        chain += inputTrack.handles
        chain += [LevelsHandleKind.inBlack, .gamma, .inWhite].compactMap { fields[$0] }
        chain += outputTrack.handles
        chain += [LevelsHandleKind.outBlack, .outWhite].compactMap { fields[$0] }
        chain += [autoContrastButton, autoColorButton, resetButton]
        for (a, b) in zip(chain, chain.dropFirst()) { a.nextKeyView = b }
    }

    // MARK: ⌥ = Reset Channel

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, flagsMonitor == nil {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                let option = event.modifierFlags.contains(.option)
                MainActor.assumeIsolated { self?.setOptionHeld(option) }
                return event
            }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
            setOptionHeld(false)
        }
    }

    /// "Reset Channel" while ⌥ is held.
    func setOptionHeld(_ held: Bool) {
        let title = held ? "Reset Channel" : "Reset"
        guard resetButton.title != title else { return }
        resetButton.title = title
        resetButton.toolTip = held ? "Reset \(channel.title) Channel" : "Reset All Channels"
    }

    // MARK: Public setters

    /// Show `p` (after undo / redo / a tool switch / an auto). Does not
    /// write and does not touch the status line.
    func setParams(_ p: LevelsParams) {
        params = p
        refreshAll()
    }

    func setChannel(_ c: LevelsPanelChannel) {
        channel = c
        channelPopup.selectItem(at: c.rawValue)
        histogramView.soloChannel = c.soloHistogramChannel
        refreshAll()
    }

    /// The histogram of the image as it enters Levels.
    func setHistogram(_ data: HistogramData?) {
        var s = histogramView.state
        s.data = data
        s.isStale = false
        histogramView.state = s
    }

    /// The status line; nil clears it. Posted to VoiceOver.
    func showStatus(_ text: String?) {
        statusLabel.stringValue = text ?? ""
        guard let text, !text.isEmpty else { return }
        NSAccessibility.post(element: statusLabel, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    // MARK: Refresh

    private func refreshAll() {
        let c = params[channel]
        for kind in LevelsHandleKind.allCases {
            fields[kind]?.stringValue = LevelsRules.text(kind, of: c)
        }
        var inPos: [LevelsHandleKind: Double] = [:]
        for kind in [LevelsHandleKind.inBlack, .gamma, .inWhite] {
            inPos[kind] = LevelsRules.position(kind, of: c)
        }
        inputTrack.positions = inPos
        outputTrack.positions = [.outBlack: LevelsRules.position(.outBlack, of: c),
                                 .outWhite: LevelsRules.position(.outWhite, of: c)]
        for h in inputTrack.handles + outputTrack.handles {
            let v = LevelsRules.value(h.kind, of: c)
            h.setAccessibilityValue(h.kind == .gamma ? String(format: "%.2f", v) : String(Int(v)))
            let range = accessibilityRange(h.kind, c)
            h.setAccessibilityMinValue(range.lowerBound)
            h.setAccessibilityMaxValue(range.upperBound)
        }
    }

    private func accessibilityRange(_ kind: LevelsHandleKind, _ c: LevelsChannel) -> ClosedRange<Double> {
        switch kind {
        case .inBlack: return 0...Double(max(Int(c.inWhite) - 2, 0))
        case .inWhite: return Double(min(Int(c.inBlack) + 2, 255))...255
        case .gamma: return LevelsChannel.gammaRange
        case .outBlack, .outWhite: return 0...255
        }
    }

    // MARK: Edits

    /// Sets one handle on the shown channel. Returns false when nothing
    /// changed.
    @discardableResult
    private func set(_ kind: LevelsHandleKind, to value: Double) -> Bool {
        let before = params[channel]
        let after = LevelsRules.setting(kind, to: value, in: before)
        guard after != before else { return false }
        params[channel] = after
        showStatus(nil)
        refreshAll()
        return true
    }

    private func dragHandle(_ kind: LevelsHandleKind, toTrackX x: CGFloat, on track: LevelsTrackView, ended: Bool) {
        let value = LevelsRules.value(kind, at: track.t(for: x), in: params[channel])
        let changed = set(kind, to: value)
        if ended {
            onEditEnded?(params)
        } else if changed {
            onParamsChanged?(params)
        }
    }

    /// Arrow keys (visual: → moves the handle right, so the midtones
    /// value goes down) and VoiceOver / ↑↓ (value up or down).
    private func stepHandle(_ kind: LevelsHandleKind, direction: Double, big: Bool, visual: Bool) {
        // `direction` is ±1, or ±10 for ⇧↑ / ⇧↓.
        let sign: Double = direction < 0 ? -1 : 1
        var delta = sign * kind.step(big: big || abs(direction) >= 10)
        if visual, kind == .gamma { delta = -delta }
        guard set(kind, to: LevelsRules.value(kind, of: params[channel]) + delta) else { return }
        onParamsCommitted?(params)
    }

    @objc private func fieldCommitted(_ sender: NSTextField) {
        guard let kind = fields.first(where: { $0.value === sender })?.key else { return }
        let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(text) else {
            refreshAll()   // not a number: show the current value again
            return
        }
        if set(kind, to: value) {
            onEditEnded?(params)
        } else {
            refreshAll()   // clamped back to the same value: show it
        }
    }

    @objc private func channelPicked(_ sender: NSPopUpButton) {
        guard let c = LevelsPanelChannel(rawValue: sender.indexOfSelectedItem) else { return }
        showStatus(nil)
        setChannel(c)
    }

    @objc private func autoContrastPressed(_ sender: Any?) { onAuto?(.contrast) }
    @objc private func autoColorPressed(_ sender: Any?) { onAuto?(.color) }

    @objc private func resetPressed(_ sender: Any?) {
        let option = NSApp?.currentEvent?.modifierFlags.contains(.option) ?? false
        reset(channelOnly: option)
    }

    /// Reset: every channel back to identity; ⌥ = the shown
    /// channel only. One undo step (none when nothing changes).
    func reset(channelOnly: Bool) {
        showStatus(nil)
        var next = params
        if channelOnly {
            next[channel] = .identity
        } else {
            next = .identity
        }
        params = next
        refreshAll()
        onEditEnded?(next)
    }

    // MARK: Test seams

    func _handle(_ kind: LevelsHandleKind) -> LevelsHandleView? {
        (inputTrack.handles + outputTrack.handles).first { $0.kind == kind }
    }
    func _field(_ kind: LevelsHandleKind) -> NSTextField? { fields[kind] }
    var _autoContrastButton: NSButton { autoContrastButton }
    var _autoColorButton: NSButton { autoColorButton }
    var _resetButton: NSButton { resetButton }
    var _statusLabel: NSTextField { statusLabel }
    var _channelPopup: NSPopUpButton { channelPopup }
    var _histogramView: HistogramPlotView { histogramView }
    var _inputTrack: LevelsTrackView { inputTrack }

    /// A drag of `kind` through `values` (handle values), then mouse up.
    func _drag(_ kind: LevelsHandleKind, through values: [Double]) {
        for v in values {
            if set(kind, to: v) { onParamsChanged?(params) }
        }
        onEditEnded?(params)
    }
}
