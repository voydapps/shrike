//
//  ToolbarItemLookTests.swift
//  ShrikeUITests
//
//  The viewer toolbar's view items (the `ToolbarToggleButton`
//  toggles and the Zoom pull-down, made for VoiceOver) look and
//  size like the system items they stand in for: a plain bordered image
//  item and an `NSMenuToolbarItem` with `showsIndicator = true`.
//  Each real item sits next to a system reference item with the
//  same symbol in an offscreen window; both are drawn with `layer.render`
//  in light and dark and must match: same frame, same glyph pixels, no
//  pressed look when on, the same glass grouping on macOS 26.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

/// Serves system reference items next to the real viewer items.
@MainActor
private final class LookDelegate: NSObject, NSToolbarDelegate {
    static let refInfo = NSToolbarItem.Identifier("look.ref.info")
    static let refFlag = NSToolbarItem.Identifier("look.ref.flag")
    static let refZoom = NSToolbarItem.Identifier("look.ref.zoom")
    static let refRating = NSToolbarItem.Identifier("look.ref.rating")
    /// A toggle with a push-on-push-off type, on: what a pressed look
    /// draws (proves the render sees one).
    static let pressed = NSToolbarItem.Identifier("look.pressed")

    let viewer: ViewerWindowToolbar
    let ids: [NSToolbarItem.Identifier]
    /// Real toggles switched on before the toolbar shows them.
    let on: Set<NSToolbarItem.Identifier>

    init(viewer: ViewerWindowToolbar, ids: [NSToolbarItem.Identifier], on: Set<NSToolbarItem.Identifier>) {
        self.viewer = viewer
        self.ids = ids
        self.on = on
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func symbol(_ name: String) -> NSImage { NSImage(systemSymbolName: name, accessibilityDescription: name)! }
        switch id {
        case Self.refInfo, Self.refFlag:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = symbol(id == Self.refInfo ? "info.circle" : "flag")
            item.isBordered = true
            item.target = self
            item.action = #selector(noop(_:))
            item.autovalidates = false
            item.label = id.rawValue
            return item
        case Self.refZoom, Self.refRating:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = symbol(id == Self.refZoom ? "plus.magnifyingglass" : "star")
            item.showsIndicator = id == Self.refZoom
            item.menu = NSMenu(title: "ref")
            item.autovalidates = false
            item.label = id.rawValue
            return item
        case Self.pressed:
            let item = NSToolbarItem(itemIdentifier: id)
            let button = ToolbarToggleButton(command: .toggleInspector, image: symbol("info.circle"), label: "Pressed")
            button.setButtonType(.pushOnPushOff)
            button.isOn = true
            item.view = button
            item.label = id.rawValue
            return item
        default:
            // The real viewer items, built by the viewer toolbar itself.
            let item = viewer.toolbar(viewer.toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: false)
            if on.contains(id) { (item?.view as? ToolbarToggleButton)?.isOn = true }
            return item
        }
    }

    @objc func noop(_ sender: Any?) {}
}

@MainActor
final class ToolbarItemLookTests: XCTestCase {

    private typealias ID = ViewerWindowToolbar.ID

    private var window: NSWindow?
    private var delegate: LookDelegate?

    override func tearDown() {
        window?.toolbar = nil
        window?.close()
        window = nil
        delegate = nil
        super.tearDown()
    }

    /// Reference and real items in pairs, spaces between the pairs.
    private func makeBar(_ appearance: NSAppearance.Name, on: Set<NSToolbarItem.Identifier> = []) -> NSToolbar {
        let viewer = ViewerWindowToolbar(host: nil)
        viewer.toolbar.autosavesConfiguration = false
        let ids: [NSToolbarItem.Identifier] = [
            LookDelegate.refInfo, ID.inspector, .space,
            LookDelegate.refZoom, ID.zoom, .space,
            LookDelegate.refFlag, ID.flag, LookDelegate.refRating, ID.rating, .space,
            LookDelegate.pressed,
        ]
        let delegate = LookDelegate(viewer: viewer, ids: ids, on: on)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 200),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: appearance)
        w.toolbarStyle = .unified
        let bar = NSToolbar(identifier: "shrike.tests.toolbarLook.\(appearance.rawValue)")
        bar.displayMode = .iconOnly
        bar.autosavesConfiguration = false
        bar.delegate = delegate
        w.toolbar = bar
        window = w
        self.delegate = delegate
        settle(bar)
        return bar
    }

    /// The toolbar sizes and draws its items over several run-loop turns
    /// (one display pass was not always enough, so the glyph pixels of a
    /// late item could differ). Lay out, draw and spin the run loop until
    /// every item's control keeps the same frame and the same drawn ink
    /// for three passes in a row (at most 200 passes, 2 s).
    private func settle(_ bar: NSToolbar) {
        guard let w = window else { return }
        var last: [String] = []
        var stable = 0
        for _ in 0..<200 {
            w.contentView?.superview?.layoutSubtreeIfNeeded()
            w.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            let now: [String] = bar.items.map { item in
                guard let c = controlIfReady(bar, item) else { return "\(item.itemIdentifier.rawValue) none" }
                let drawn = ink(c).map { "\($0.box) \(Int($0.coverage * 100))" } ?? "nil"
                return "\(item.itemIdentifier.rawValue) \(c.frame) \(drawn)"
            }
            stable = now == last ? stable + 1 : 0
            last = now
            if stable >= 3 { return }
        }
    }

    /// `control(_:_:)` without the failures, for polling.
    private func controlIfReady(_ bar: NSToolbar, _ item: NSToolbarItem) -> NSControl? {
        if let view = item.view as? NSControl { return view }
        guard let root = window?.contentView?.superview else { return nil }
        func find(_ v: NSView) -> NSControl? {
            if String(describing: type(of: v)) == "NSToolbarItemViewer",
               v.responds(to: NSSelectorFromString("item")),
               (v.value(forKey: "item") as? NSToolbarItem) === item {
                return v.subviews.compactMap { $0 as? NSControl }.first
            }
            for sub in v.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        return find(root)
    }

    /// The control AppKit shows for `id` (a system item's own button, or
    /// the item's view).
    private func control(_ bar: NSToolbar, _ id: NSToolbarItem.Identifier,
                         file: StaticString = #filePath, line: UInt = #line) -> NSControl? {
        guard let item = bar.items.first(where: { $0.itemIdentifier == id }) else {
            XCTFail("no item \(id.rawValue)", file: file, line: line)
            return nil
        }
        if let view = item.view as? NSControl { return view }
        guard let root = window?.contentView?.superview else { return nil }
        func find(_ v: NSView) -> NSControl? {
            if String(describing: type(of: v)) == "NSToolbarItemViewer",
               v.responds(to: NSSelectorFromString("item")),
               (v.value(forKey: "item") as? NSToolbarItem) === item {
                return v.subviews.compactMap { $0 as? NSControl }.first
            }
            for sub in v.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        let hit = find(root)
        XCTAssertNotNil(hit, "no control for \(id.rawValue)", file: file, line: line)
        return hit
    }

    /// The control drawn offscreen (`layer.render`, y-flipped), as RGBA.
    private func pixels(_ view: NSView) -> (w: Int, h: Int, rgba: [UInt8])? {
        view.window?.displayIfNeeded()
        let scale: CGFloat = 2
        let size = view.bounds.size
        guard size.width > 0, size.height > 0, let layer = view.layer else { return nil }
        let w = Int(size.width * scale), h = Int(size.height * scale)
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.scaleBy(x: scale, y: scale)
            if !view.isFlipped {
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
            }
            layer.render(in: ctx)
            return true
        }
        return ok ? (w, h, buf) : nil
    }

    /// Glyph ink: the box of drawn pixels and the summed coverage.
    private func ink(_ view: NSView) -> (box: CGRect, coverage: Double)? {
        guard let p = pixels(view) else { return nil }
        var minX = p.w, minY = p.h, maxX = -1, maxY = -1
        var sum = 0.0
        for y in 0..<p.h {
            for x in 0..<p.w {
                let a = Double(p.rgba[(y * p.w + x) * 4 + 3]) / 255
                sum += a
                if a > 0.1 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard maxX >= minX else { return (.zero, 0) }
        return (CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1), sum)
    }

    private func assertLooksAlike(_ real: NSControl?, _ ref: NSControl?, _ what: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard let real, let ref else { return }
        XCTAssertGreaterThan(ref.frame.height, 16, "\(what): the toolbar never laid out", file: file, line: line)
        XCTAssertEqual(real.frame.height, ref.frame.height, accuracy: 0.5, "\(what): height", file: file, line: line)
        XCTAssertEqual(real.frame.width, ref.frame.width, accuracy: 0.5, "\(what): width", file: file, line: line)
        guard let a = ink(real), let b = ink(ref) else {
            return XCTFail("\(what): nothing drawn", file: file, line: line)
        }
        XCTAssertGreaterThan(b.coverage, 0, "\(what): the reference drew nothing", file: file, line: line)
        XCTAssertEqual(a.box.width, b.box.width, accuracy: 1, "\(what): glyph width", file: file, line: line)
        XCTAssertEqual(a.box.height, b.box.height, accuracy: 1, "\(what): glyph height", file: file, line: line)
        XCTAssertEqual(a.coverage, b.coverage, accuracy: max(1, b.coverage * 0.02),
                       "\(what): glyph weight (ink)", file: file, line: line)
    }

    // MARK: Tests

    func testTogglesMatchThePlainImageItemInLightAndDark() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let bar = makeBar(appearance)
            let name = appearance == .aqua ? "light" : "dark"
            assertLooksAlike(control(bar, ID.inspector), control(bar, LookDelegate.refInfo), "Inspector (\(name))")
            assertLooksAlike(control(bar, ID.flag), control(bar, LookDelegate.refFlag), "Flag (\(name))")
            tearDown()
        }
    }

    func testToggleHasNoPressedLookWhenOn() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let bar = makeBar(appearance, on: [ID.inspector, ID.flag])
            let inspector = try XCTUnwrap(control(bar, ID.inspector) as? ToolbarToggleButton)
            XCTAssertTrue(inspector.isOn)
            // On draws exactly the plain (stateless) item.
            assertLooksAlike(inspector, control(bar, LookDelegate.refInfo), "Inspector on (\(appearance.rawValue))")
            assertLooksAlike(control(bar, ID.flag), control(bar, LookDelegate.refFlag), "Flag on (\(appearance.rawValue))")
            // The render does see a pressed look when there is one.
            let plain = try XCTUnwrap(ink(inspector))
            let pressed = try XCTUnwrap(control(bar, LookDelegate.pressed).flatMap(ink))
            XCTAssertGreaterThan(pressed.coverage, plain.coverage * 3,
                                 "a push-on-push-off toggle should draw a platter when on")
            tearDown()
        }
    }

    func testToggleUsesTheSystemToolbarButtonSettings() throws {
        let bar = makeBar(.darkAqua)
        let real = try XCTUnwrap(control(bar, ID.flag) as? NSButton)
        let ref = try XCTUnwrap(control(bar, LookDelegate.refFlag) as? NSButton)
        XCTAssertEqual(real.bezelStyle, ref.bezelStyle)
        XCTAssertEqual(real.isBordered, ref.isBordered)
        XCTAssertEqual(real.imagePosition, ref.imagePosition)
        XCTAssertEqual(real.imageScaling, ref.imageScaling)
        XCTAssertEqual(real.controlSize, ref.controlSize, "the toolbar sizes both alike")
        // No state background: the toggle shows its state by contents only.
        let cell = try XCTUnwrap(real.cell as? NSButtonCell)
        XCTAssertFalse(cell.showsStateBy.contains(.changeBackgroundCellMask))
        XCTAssertFalse(cell.showsStateBy.contains(.pushInCellMask))
    }

    func testZoomPullDownMatchesAMenuItemWithItsIndicator() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let bar = makeBar(appearance)
            let real = control(bar, ID.zoom)
            let ref = control(bar, LookDelegate.refZoom)
            assertLooksAlike(real, ref, "Zoom (\(appearance.rawValue))")
            let realCell = try XCTUnwrap((real as? NSPopUpButton)?.cell as? NSPopUpButtonCell)
            XCTAssertNotEqual(realCell.arrowPosition, .noArrow, "Zoom shows its pull-down arrow")
            if let refCell = (ref as? NSPopUpButton)?.cell as? NSPopUpButtonCell {
                XCTAssertEqual(realCell.arrowPosition, refCell.arrowPosition)
            }
            // Wider than the arrowless Rating pull-down: the arrow is drawn.
            if let rating = control(bar, LookDelegate.refRating), let real {
                XCTAssertGreaterThan(real.frame.width, rating.frame.width + 4)
            }
            tearDown()
        }
    }

    /// Rating became a pull-down view (for its VoiceOver value);
    /// it still looks like the system menu item with no indicator.
    func testRatingPullDownMatchesAMenuItemWithoutIndicator() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let bar = makeBar(appearance)
            let real = control(bar, ID.rating)
            assertLooksAlike(real, control(bar, LookDelegate.refRating), "Rating (\(appearance.rawValue))")
            let cell = try XCTUnwrap((real as? NSPopUpButton)?.cell as? NSPopUpButtonCell)
            XCTAssertEqual(cell.arrowPosition, .noArrow)
            tearDown()
        }
    }

    /// macOS 26: the toggle shares the glass capsule of its plain
    /// neighbour, and the Zoom pull-down gets a capsule of its own, like
    /// the system pull-down with an indicator.
    func testGlassGroupingMatchesOnMacOS26() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("glass toolbar is macOS 26") }
        let bar = makeBar(.darkAqua)
        guard let root = window?.contentView?.superview else { return XCTFail("no frame view") }
        var platters: [CGRect] = []
        func walk(_ v: NSView) {
            if String(describing: type(of: v)).contains("Platter"), !v.isHidden {
                platters.append(v.convert(v.bounds, to: nil))
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        try XCTSkipIf(platters.isEmpty, "this macOS draws no toolbar platters")
        func capsule(_ id: NSToolbarItem.Identifier) -> CGRect? {
            guard let c = control(bar, id) else { return nil }
            let r = c.convert(c.bounds, to: nil)
            let mid = CGPoint(x: r.midX, y: r.midY)
            return platters.first { $0.contains(mid) }
        }
        let refInfo = capsule(LookDelegate.refInfo), inspector = capsule(ID.inspector)
        XCTAssertNotNil(inspector, "the toggle sits on a glass capsule")
        XCTAssertEqual(inspector, refInfo, "the toggle shares its plain neighbour's capsule")
        let refFlag = capsule(LookDelegate.refFlag), flag = capsule(ID.flag)
        XCTAssertEqual(flag, refFlag, "Flag shares the capsule with its neighbours")
        XCTAssertEqual(capsule(ID.rating), capsule(LookDelegate.refRating),
                       "Rating shares the capsule with the system rating item beside it")
        let refZoom = capsule(LookDelegate.refZoom), zoom = capsule(ID.zoom)
        XCTAssertNotNil(zoom)
        XCTAssertEqual(zoom?.width ?? 0, refZoom?.width ?? -1, accuracy: 0.5,
                       "Zoom's capsule is like the system pull-down's")
    }
}
