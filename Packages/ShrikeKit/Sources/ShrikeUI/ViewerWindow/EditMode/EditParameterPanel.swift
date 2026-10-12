//
//  EditParameterPanel.swift
//  ShrikeUI
//
//  Right-side container that hosts whichever tool panel the user is
//  currently driving. Spec
//
//  Width: 280 pt, flush with the right edge, full canvas height minus
//  the toolbar + status strip. Only one tool panel is installed at a
//  time — switching tools destroys the previous content and installs
//  the new one, so each tool's panel starts fresh on every entry.
//

import AppKit
import ShrikeRendering

@MainActor
final class EditParameterPanel: HUDSurfaceView {

    /// The panel currently installed, or `nil` when no tool is active.
    private(set) var installed: NSView?

    /// Width used for the panel.
    static let panelWidth: CGFloat = 280

    init() {
        super.init(frame: .zero)
        // The same surface, radius, hairline and
        // shadow as the other panels; opaque over the black canvas band.
        usesOpaqueFill = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The height available to the panel (the canvas band). A tool view taller
    /// than this scrolls (spec 25 §3.2). Nil or ≤ 0: no limit known yet.
    var bandHeightProvider: (() -> CGFloat)?

    /// The panel is as tall as its content (priority below the owner's
    /// "stay inside the band" limits).
    private var heightConstraint: NSLayoutConstraint?
    private var scrollWrapper: NSScrollView?
    /// Content height of the installed view (tests).
    private(set) var contentHeight: CGFloat = 0
    var isScrolling: Bool { scrollWrapper != nil }

    /// Replace the installed panel with `view`. Pass `nil` to clear.
    func install(_ view: NSView?) {
        let previousHeight = heightConstraint?.constant
        installed?.removeFromSuperview()
        scrollWrapper?.removeFromSuperview()
        scrollWrapper = nil
        heightConstraint?.isActive = false
        heightConstraint = nil
        installed = view
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: Self.panelWidth).isActive = true
        let height = ceil(view.fittingSize.height)
        contentHeight = height

        let band = bandHeightProvider?() ?? 0
        if band > 0, height > band {
            let scroll = NSScrollView()
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            addSubview(scroll)
            scroll.documentView = view
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: topAnchor),
                scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
                scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                view.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
                view.heightAnchor.constraint(equalToConstant: height),
            ])
            scrollWrapper = scroll
        } else {
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }

        let constraint = heightAnchor.constraint(equalToConstant: height)
        constraint.priority = .defaultHigh
        constraint.isActive = true
        heightConstraint = constraint
        // A tool change eases the height over 120 ms; Reduce Motion: at once.
        if let previousHeight, previousHeight > 0, previousHeight != height, window != nil, !ReduceMotion.isOn {
            constraint.constant = previousHeight
            layoutSubtreeIfNeeded()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.allowsImplicitAnimation = true
                constraint.animator().constant = height
            }
        }
    }

    // MARK: - Test seam

    internal var _installed: NSView? { installed }
}

/// The panel slot's empty state while no tool is chosen.
@MainActor
final class ChooseToolPanel: NSView {

    static let title = "Choose a Tool"

    /// Spec 26 §1.6: the picker is icon-only, so this text names the tools and says where they are.
    static func body(inFullScreen: Bool) -> String {
        "Pick Crop, Rotate, Resize, Color or Levels in the bar at the \(inFullScreen ? "bottom" : "top")."
    }

    let titleLabel = NSTextField(labelWithString: ChooseToolPanel.title)
    let bodyLabel: NSTextField

    /// Where the bar is: the window's top bar or the full-screen bottom capsule.
    var inFullScreen: Bool {
        didSet { bodyLabel.stringValue = Self.body(inFullScreen: inFullScreen) }
    }

    init(inFullScreen: Bool = false) {
        self.inFullScreen = inFullScreen
        bodyLabel = NSTextField(wrappingLabelWithString: Self.body(inFullScreen: inFullScreen))
        super.init(frame: .zero)
        // The tool-title style (the Levels panel header).
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.isSelectable = false
        let stack = NSStackView(views: [titleLabel, bodyLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic only") }
}
