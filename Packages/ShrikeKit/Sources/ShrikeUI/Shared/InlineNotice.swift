import AppKit

/// Compact task notice with native keyboard actions and selectable detail.
@MainActor
final class InlineNotice: NSStackView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private var actions: [Action] = []
    private var bar: ExactProgressBar?
    var onVisibilityChanged: ((Bool) -> Void)?
    /// Height of a notice that must not change between its states (progress
    /// and result), so the photos below never jump: room for the Undo button.
    static let fixedBandHeight: CGFloat = 32

    init(fixedHeight: CGFloat? = nil) {
        super.init(frame: .zero)
        if let fixedHeight {
            heightAnchor.constraint(equalToConstant: fixedHeight).isActive = true
            // One line, so the text is as tall as its line (a wrapping label stretches
            // to the band and draws its text at the top, above the button's centre).
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.required, for: .vertical)
        orientation = .horizontal; spacing = 8
        edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        label.font = ChromeTypography.font(12); label.isSelectable = true
        addArrangedSubview(label); isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    /// The message shown ("" when hidden) and the action buttons' titles.
    var message: String { isHidden ? "" : label.stringValue }
    var buttonTitles: [String] { arrangedSubviews.compactMap { ($0 as? NSButton)?.title } }
    /// True while a progress bar is shown.
    var isShowingProgress: Bool { !isHidden && bar != nil }
    /// The bar's value (nil = busy, no number).
    var progressFraction: Double? { bar?.fraction }

    /// A running task: the message and a small bar. A later `show` replaces it.
    func showProgress(_ text: String, fraction: Double?) {
        let isNew = bar == nil || isHidden
        if isNew {
            show(text)
            let indicator = ExactProgressBar()
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicator.widthAnchor.constraint(equalToConstant: 140).isActive = true
            addArrangedSubview(indicator)
            bar = indicator
        }
        label.stringValue = text
        guard let bar else { return }
        bar.set(fraction: fraction, label: text)
    }

    func show(_ text: String?, buttons: [(String, () -> Void)] = []) {
        for view in arrangedSubviews where view !== label { removeArrangedSubview(view); view.removeFromSuperview() }
        bar?.stopBusy(); bar = nil
        actions = []; label.stringValue = text ?? ""; isHidden = text == nil
        for (title, body) in buttons {
            let action = Action(body); actions.append(action)
            let button = NSButton(title: title, target: action, action: #selector(Action.run))
            button.bezelStyle = .rounded; addArrangedSubview(button)
        }
        onVisibilityChanged?(isHidden)
    }
    private final class Action: NSObject {
        let body: () -> Void
        init(_ body: @escaping () -> Void) { self.body = body }
        @objc func run() { body() }
    }
}
