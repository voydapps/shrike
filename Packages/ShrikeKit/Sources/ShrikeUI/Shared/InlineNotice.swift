import AppKit

/// Compact task notice with native keyboard actions and selectable detail.
@MainActor
final class InlineNotice: NSStackView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private var actions: [Action] = []
    var onVisibilityChanged: ((Bool) -> Void)?
    init() {
        super.init(frame: .zero)
        orientation = .horizontal; spacing = 8
        edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        label.font = ChromeTypography.font(12); label.isSelectable = true
        addArrangedSubview(label); isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ text: String?, buttons: [(String, () -> Void)] = []) {
        for view in arrangedSubviews where view !== label { removeArrangedSubview(view); view.removeFromSuperview() }
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
