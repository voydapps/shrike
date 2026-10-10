//
//  EditParameterPanel.swift
//  ShrikeUI
//
//  Right-rail container that hosts whichever tool panel the user is
//  currently driving. Spec
//
//  Width: 280 pt, flush with the right edge, full canvas height minus
//  the toolbar + status strip. Only one tool panel is installed at a
//  time — switching tools destroys the previous content and installs
//  the new one, so each tool's panel starts fresh on every entry.
//

import AppKit

@MainActor
final class EditParameterPanel: HUDSurfaceView {

    /// The panel currently installed, or `nil` when no tool is active.
    private(set) var installed: NSView?

    /// Width used for the panel.
    static let panelWidth: CGFloat = 280

    init() {
        super.init(frame: .zero)
        // The same surface, radius, hairline and
        // shadow as the rail; opaque over the black canvas band.
        usesOpaqueFill = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Replace the installed panel with `view`. Pass `nil` to clear.
    func install(_ view: NSView?) {
        installed?.removeFromSuperview()
        installed = view
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    // MARK: - Test seam

    internal var _installed: NSView? { installed }
}

/// The panel slot's empty state while no tool is chosen.
@MainActor
final class ChooseToolPanel: NSView {

    static let title = "Choose a Tool"
    static let body = "Pick Crop, Rotate, Resize, Color or Levels."

    let titleLabel = NSTextField(labelWithString: ChooseToolPanel.title)
    let bodyLabel = NSTextField(wrappingLabelWithString: ChooseToolPanel.body)

    init() {
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
