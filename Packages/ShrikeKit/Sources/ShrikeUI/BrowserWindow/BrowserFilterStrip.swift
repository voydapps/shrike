import AppKit

struct BrowserFilterCondition {
    enum Key { case search, rating, flag, kinds, formats, dates, tags }
    let key: Key
    let title: String
}

extension BrowserFilterCondition.Key {
    /// The word VoiceOver says in "Remove … filter".
    var accessibilityName: String {
        switch self {
        case .search: return "search"
        case .rating: return "rating"
        case .flag: return "flag"
        case .kinds: return "kinds"
        case .formats: return "formats"
        case .dates: return "date range"
        case .tags: return "tags"
        }
    }
}

extension BrowserFilter {
    var conditions: [BrowserFilterCondition] {
        var out: [BrowserFilterCondition] = []
        if !searchTerm.isEmpty { out.append(.init(key: .search, title: "Name contains “\(searchTerm)”")) }
        if minimumRating > 0 || unratedOnly { out.append(.init(key: .rating, title: unratedOnly ? "Unrated" : "\(minimumRating) stars or more")) }
        if flaggedOnly || unflaggedOnly { out.append(.init(key: .flag, title: flaggedOnly ? "Flagged" : "Not flagged")) }
        if !excludedKinds.isEmpty {
            out.append(.init(key: .kinds, title: "Kinds: " + BrowserFilterKind.allCases.filter { !excludedKinds.contains($0) }.map(\.title).joined(separator: ", ")))
        }
        if !formats.isEmpty { out.append(.init(key: .formats, title: "Formats: " + formats.map(\.rawValue).sorted().joined(separator: ", "))) }
        if modifiedFrom != nil || modifiedTo != nil { out.append(.init(key: .dates, title: "Date range")) }
        if !tags.isEmpty { out.append(.init(key: .tags, title: "Tags: " + tags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: ", "))) }
        return out
    }
    func removing(_ key: BrowserFilterCondition.Key) -> BrowserFilter {
        var copy = self
        switch key {
        case .search: copy.searchTerm = ""
        case .rating: copy.minimumRating = 0; copy.unratedOnly = false
        case .flag: copy.flaggedOnly = false; copy.unflaggedOnly = false
        case .kinds: copy.excludedKinds = []
        case .formats: copy.formats = []
        case .dates: copy.modifiedFrom = nil; copy.modifiedTo = nil
        case .tags: copy.tags = []
        }
        return copy
    }
    var requiresMarkHydration: Bool { minimumRating > 0 || unratedOnly || flaggedOnly || unflaggedOnly || !tags.isEmpty }
}

@MainActor
final class BrowserFilterStrip: NSView {
    var onChange: ((BrowserFilter) -> Void)?
    private let chips = NSStackView()
    private let clear = NSButton(title: "Clear All", target: nil, action: nil)
    private var actions: [Action] = []
    private var filter = BrowserFilter.none
    private var rowHeight: NSLayoutConstraint!
    private var scrollTop: NSLayoutConstraint!
    private var scrollBottom: NSLayoutConstraint!
    override init(frame: NSRect) {
        super.init(frame: frame)
        let scroll = NSScrollView(); scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = chips
        chips.orientation = .horizontal; chips.spacing = 6
        for v in [scroll, clear] { addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false }
        chips.translatesAutoresizingMaskIntoConstraints = false
        clear.target = self; clear.action = #selector(clearAll)
        rowHeight = heightAnchor.constraint(equalToConstant: 0)
        scrollTop = scroll.topAnchor.constraint(equalTo: topAnchor)
        scrollBottom = scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([rowHeight, scrollTop, scrollBottom,
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: clear.leadingAnchor, constant: -8),
            chips.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), chips.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            chips.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            clear.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), clear.centerYAnchor.constraint(equalTo: centerYAnchor)])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ value: BrowserFilter) {
        filter = value
        chips.arrangedSubviews.forEach { chips.removeArrangedSubview($0); $0.removeFromSuperview() }
        actions = []
        for condition in value.conditions {
            let button = NSButton(title: condition.title + "  ×", target: nil, action: nil)
            button.bezelStyle = .rounded
            button.font = ChromeTypography.font(12)
            button.setAccessibilityLabel("Remove \(condition.key.accessibilityName) filter: \(condition.title)")
            button.toolTip = condition.title
            let action = Action { [weak self] in self?.onChange?(value.removing(condition.key)) }
            actions.append(action); button.target = action; button.action = #selector(Action.run)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: ChromeTypography.targetHeight).isActive = true
            chips.addArrangedSubview(button)
        }
        if value.isEmpty {
            scrollTop.constant = 0; scrollBottom.constant = 0
            rowHeight.constant = 0
        } else {
            rowHeight.constant = ChromeTypography.targetHeight + 4
            scrollTop.constant = 2; scrollBottom.constant = -2
        }
        isHidden = value.isEmpty
    }
    @objc private func clearAll() { onChange?(.none) }
    private final class Action: NSObject {
        let body: () -> Void
        init(_ body: @escaping () -> Void) { self.body = body }
        @objc func run() { body() }
    }
}
