import AppKit
import ShrikeCore

@MainActor
final class ReviewControls: HUDSurfaceView {
    var onNavigate: ((Bool) -> Void)?
    var onRate: ((Int) -> Void)?
    var onFlag: (() -> Void)?
    private var actions: [Action] = []
    private(set) var buttons: [NSButton] = []
    private let padding: CGFloat = 8
    private let gap: CGFloat = 4
    private let advance = NSButton(checkboxWithTitle: "Advance after rating", target: nil, action: nil)
    private var ratings: [NSButton] = []
    private let flag = NSButton(title: "Flag", target: nil, action: nil)
    override init(frame: NSRect) {
        super.init(frame: frame)
        usesOpaqueFill = true
        // Wrapping owns the minimum width. A full-row intrinsic width must
        // not force NSWindow to enlarge the photo canvas at narrow sizes.
        setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        add("Previous") { [weak self] in self?.onNavigate?(false) }
        for stars in 1...5 { ratings.append(add("\(stars)★") { [weak self] in self?.onRate?(stars) }) }
        add("Clear Rating") { [weak self] in self?.onRate?(0) }
        flag.target = self; flag.action = #selector(toggleFlag); append(flag)
        add("Next") { [weak self] in self?.onNavigate?(true) }
        advance.target = self; advance.action = #selector(toggleAdvance); append(advance)
        for (button, next) in zip(buttons, buttons.dropFirst()) { button.nextKeyView = next }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Photo review controls")
    }
    required init?(coder: NSCoder) { fatalError() }
    @discardableResult private func add(_ title: String, _ body: @escaping () -> Void) -> NSButton {
        let target = Action(body); actions.append(target)
        let button = NSButton(title: title, target: target, action: #selector(Action.run))
        button.bezelStyle = .rounded; button.font = ChromeTypography.font(12)
        append(button); return button
    }
    private func append(_ button: NSButton) {
        button.font = ChromeTypography.font(12)
        buttons.append(button); contentHost.addSubview(button)
    }
    private func rows(for width: CGFloat) -> [[NSButton]] {
        let available = max(1, width - padding * 2)
        var rows: [[NSButton]] = [[]], used: CGFloat = 0
        for button in buttons {
            let required = ceil(button.fittingSize.width)
            if used > 0, used + gap + required > available { rows.append([]); used = 0 }
            rows[rows.count - 1].append(button)
            used += (used > 0 ? gap : 0) + required
        }
        return rows
    }
    private var rowHeight: CGFloat {
        max(ChromeTypography.targetHeight, buttons.map { ceil($0.fittingSize.height) }.max() ?? 0)
    }
    override var intrinsicContentSize: NSSize {
        let natural = buttons.reduce(padding * 2 - gap) { $0 + ceil($1.fittingSize.width) + gap }
        let width = bounds.width > 0 ? min(bounds.width, natural) : natural
        let count = rows(for: width).count
        return NSSize(width: natural, height: padding * 2 + CGFloat(count) * rowHeight + CGFloat(count - 1) * gap)
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { invalidateIntrinsicContentSize() }
    }
    override func layout() {
        super.layout()
        if abs(intrinsicContentSize.height - bounds.height) > 0.5 { invalidateIntrinsicContentSize() }
        let rows = rows(for: bounds.width)
        var y = bounds.height - padding - rowHeight
        for row in rows {
            var x = padding
            for button in row {
                let width = ceil(button.fittingSize.width)
                button.frame = NSRect(x: x, y: y, width: width, height: rowHeight)
                x += width + gap
            }
            y -= rowHeight + gap
        }
    }
    func update(record: FileRecord, durable: Bool) {
        for (index, button) in ratings.enumerated() { button.state = record.rating == index + 1 ? .on : .off }
        flag.state = record.flagged ? .on : .off
        advance.state = Prefs.advanceAfterRating ? .on : .off
        advance.isEnabled = durable
        advance.toolTip = durable ? "Advance once after saving a changed rating" : "Restore ratings storage to advance automatically."
    }
    @objc private func toggleFlag() { onFlag?() }
    @objc private func toggleAdvance() { Prefs.advanceAfterRating = advance.state == .on }
    private final class Action: NSObject {
        let body: () -> Void; init(_ body: @escaping () -> Void) { self.body = body }
        @objc func run() { body() }
    }
}
