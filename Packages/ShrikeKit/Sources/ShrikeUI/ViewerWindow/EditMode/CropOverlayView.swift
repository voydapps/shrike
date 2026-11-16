//
//  CropOverlayView.swift
//  ShrikeUI
//
//  On-canvas crop overlay.
//
//  Responsibility:
//    * Draw a crop rect over the viewer image with 8 handles (4 corners +
//      4 edge mid-points) plus optional thirds / golden grids inside.
//    * Dim the area outside the rect with 50% black.
//    * Hit-test handles and body for drag / resize. Shift-drag locks to
//      the current aspect.
//    * Arrow keys nudge the rect by 1px; Shift-Arrow by 10px.
//    * Emit `onRectChanged` (image-space pixel rect) whenever the user
//      modifies the rect so the parameter panel can reflect W/H.
//
//  Coordinates:
//    * The view lives in canvas space (viewport pixels). `imagePixelSize`
//      and `imageFrame` tell us where the image lives inside that frame;
//      we translate between the on-screen rect we draw and the image-
//      space rect we report.
//    * `onRectChanged` always reports an *image-space pixel* rect so the
//      parameter panel can display W/H and build `CropRect` via
//      `CropTool.normalise(rect:in:)`.
//

import AppKit
import ShrikeEdit

@MainActor
final class CropOverlayView: NSView {
    var acceptsGeometryInput = true

    /// The frame has the keyboard: the system focus ring is drawn around it.
    var hasKeyboardFocusIndication: Bool {
        window?.firstResponder === self && !isHiddenOrHasHiddenAncestor
    }

    // MARK: - Inputs

    /// Pixel size of the underlying image the user is cropping. Used to
    /// translate on-screen drags back into image-space rects.
    var imagePixelSize: CGSize = .zero {
        didSet { needsDisplay = true }
    }

    /// Frame of the image within our own bounds (upper-left origin,
    /// AppKit's `isFlipped = true`). The viewer fits the image letter-
    /// or pillar-boxed; we receive the resulting rect from the owner.
    var imageFrame: CGRect = .zero {
        didSet {
            guard imageFrame != oldValue else { return }
            if cropRect == .zero || oldValue.width <= 0 || oldValue.height <= 0
                || Self.aspectChanged(from: oldValue.size, to: imageFrame.size) {
                // A new image (rotated, cropped, first frame): the frame
                // starts on the whole image again.
                cropRect = imageFrame
            } else {
                // The same image moved or re-fitted (window resize, the
                // edit-mode re-fit): the crop keeps its place on it.
                let sx = imageFrame.width / oldValue.width
                let sy = imageFrame.height / oldValue.height
                cropRect = CGRect(
                    x: imageFrame.minX + (cropRect.minX - oldValue.minX) * sx,
                    y: imageFrame.minY + (cropRect.minY - oldValue.minY) * sy,
                    width: cropRect.width * sx, height: cropRect.height * sy
                ).intersection(imageFrame)
            }
            needsDisplay = true
        }
    }

    /// True when two frames are not the same picture scaled (a 90°
    /// rotate or a crop changed the image's shape).
    static func aspectChanged(from a: CGSize, to b: CGSize) -> Bool {
        guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return true }
        let ra = a.width / a.height, rb = b.width / b.height
        return abs(ra - rb) / max(ra, rb) > 0.01
    }

    /// Lock the rect to this aspect (W / H) on resize. `nil` = freeform.
    var aspectRatio: Double? {
        didSet { needsDisplay = true }
    }

    /// Draw thirds-grid inside the rect.
    var showThirds: Bool = false {
        didSet { needsDisplay = true }
    }

    /// Draw golden-ratio grid inside the rect.
    var showGolden: Bool = false {
        didSet { needsDisplay = true }
    }

    /// Emits whenever the rect changes. The rect is in *image-space pixels*
    /// (origin top-left, +y down). The panel converts to `CropRect` via
    /// `CropTool.normalise(rect:in:)`.
    var onRectChanged: ((CGRect) -> Void)?

    // MARK: - State

    /// The crop rect as drawn on screen (canvas coords, isFlipped = true).
    /// Initialised to `imageFrame` on first layout.
    private(set) var cropRect: CGRect = .zero {
        didSet {
            needsDisplay = true
            noteFocusRingMaskChanged()
            layoutHandleViews()
            notifyChanged()
        }
    }

    private enum Grab {
        case body
        case corner(CornerHandle)
        case edge(EdgeHandle)
    }

    private enum CornerHandle { case tl, tr, bl, br }
    private enum EdgeHandle   { case top, bottom, left, right }

    private var dragAnchor: CGPoint?
    private var dragOriginRect: CGRect?
    private var activeGrab: Grab?

    // MARK: - Appearance

    private let handleSize: CGFloat = 10
    private let handleHitSlop: CGFloat = 6

    // MARK: - View setup

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    // The system focus ring (its colour and width) follows the frame line
    // while the frame has the keyboard.
    override var focusRingMaskBounds: NSRect { cropRect.integral.insetBy(dx: -1, dy: -1) }
    override func drawFocusRingMask() {
        let ring = NSBezierPath(rect: cropRect.integral)
        ring.lineWidth = 2
        ring.stroke()
    }

    /// A hidden frame never keeps the keyboard: it goes back to the photo.
    override func viewDidHide() {
        super.viewDidHide()
        if window?.firstResponder === self { onEscape?() }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        colorObserver = LiveColorObserver(view: self)
    }
    private var colorObserver: LiveColorObserver?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return }
        let rect = cropRect.integral

        // 50% black dim outside the crop rect — fill bounds, knock out rect.
        let reduce = ReduceTransparency.isOn
        NSColor.black.withAlphaComponent(ReduceTransparency.cropDimAlpha(reduce: reduce)).setFill()
        let fullPath = NSBezierPath(rect: bounds)
        let holePath = NSBezierPath(rect: rect)
        fullPath.append(holePath.reversed)
        fullPath.windingRule = .evenOdd
        fullPath.fill()

        // Rect border.
        let lines = ReduceTransparency.cropFrameLines(reduce: reduce)
        if let outside = lines.blackOutsideWidth {
            // A 2 pt white line with a 1 pt black line just outside it.
            NSColor.black.setStroke()
            let black = NSBezierPath(rect: rect.insetBy(dx: -(lines.whiteWidth / 2 + outside / 2),
                                                        dy: -(lines.whiteWidth / 2 + outside / 2)))
            black.lineWidth = outside
            black.stroke()
        }
        NSColor.white.withAlphaComponent(lines.blackOutsideWidth == nil ? 0.9 : 1).setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = lines.whiteWidth
        border.stroke()

        if showThirds { drawThirdsGrid(in: rect) }
        if showGolden { drawGoldenGrid(in: rect) }

        drawHandles(for: rect)
    }

    private func drawThirdsGrid(in rect: CGRect) {
        NSColor.white.withAlphaComponent(0.4).setStroke()
        let path = NSBezierPath()
        let x1 = rect.minX + rect.width  / 3
        let x2 = rect.minX + rect.width  * 2 / 3
        let y1 = rect.minY + rect.height / 3
        let y2 = rect.minY + rect.height * 2 / 3
        path.move(to: NSPoint(x: x1, y: rect.minY))
        path.line(to: NSPoint(x: x1, y: rect.maxY))
        path.move(to: NSPoint(x: x2, y: rect.minY))
        path.line(to: NSPoint(x: x2, y: rect.maxY))
        path.move(to: NSPoint(x: rect.minX, y: y1))
        path.line(to: NSPoint(x: rect.maxX, y: y1))
        path.move(to: NSPoint(x: rect.minX, y: y2))
        path.line(to: NSPoint(x: rect.maxX, y: y2))
        path.lineWidth = 0.5
        path.stroke()
    }

    private func drawGoldenGrid(in rect: CGRect) {
        NSColor.systemYellow.withAlphaComponent(0.4).setStroke()
        let path = NSBezierPath()
        let phi = 1.0 / 1.6180339887
        let x1 = rect.minX + rect.width  * CGFloat(phi)
        let x2 = rect.maxX - rect.width  * CGFloat(phi)
        let y1 = rect.minY + rect.height * CGFloat(phi)
        let y2 = rect.maxY - rect.height * CGFloat(phi)
        path.move(to: NSPoint(x: x1, y: rect.minY))
        path.line(to: NSPoint(x: x1, y: rect.maxY))
        path.move(to: NSPoint(x: x2, y: rect.minY))
        path.line(to: NSPoint(x: x2, y: rect.maxY))
        path.move(to: NSPoint(x: rect.minX, y: y1))
        path.line(to: NSPoint(x: rect.maxX, y: y1))
        path.move(to: NSPoint(x: rect.minX, y: y2))
        path.line(to: NSPoint(x: rect.maxX, y: y2))
        path.lineWidth = 0.5
        path.stroke()
    }

    private func drawHandles(for rect: CGRect) {
        NSColor.white.setFill()
        NSColor.black.withAlphaComponent(0.8).setStroke()
        for point in handleCenters(for: rect) {
            let handleRect = CGRect(
                x: point.x - handleSize / 2,
                y: point.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            let h = NSBezierPath(rect: handleRect)
            h.fill()
            h.lineWidth = 1.0
            h.stroke()
        }
    }

    private func handleCenters(for rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX,            y: rect.minY),           // TL
            CGPoint(x: rect.maxX,            y: rect.minY),           // TR
            CGPoint(x: rect.minX,            y: rect.maxY),           // BL
            CGPoint(x: rect.maxX,            y: rect.maxY),           // BR
            CGPoint(x: rect.midX,            y: rect.minY),           // top
            CGPoint(x: rect.midX,            y: rect.maxY),           // bottom
            CGPoint(x: rect.minX,            y: rect.midY),           // left
            CGPoint(x: rect.maxX,            y: rect.midY),           // right
        ]
    }

    // MARK: - Hit-testing

    private func hitTestHandle(at pt: NSPoint) -> Grab? {
        let rect = cropRect
        let slop = handleSize / 2 + handleHitSlop

        // Corners first (priority over body).
        if pointNear(pt, target: CGPoint(x: rect.minX, y: rect.minY), slop: slop) {
            return .corner(.tl)
        }
        if pointNear(pt, target: CGPoint(x: rect.maxX, y: rect.minY), slop: slop) {
            return .corner(.tr)
        }
        if pointNear(pt, target: CGPoint(x: rect.minX, y: rect.maxY), slop: slop) {
            return .corner(.bl)
        }
        if pointNear(pt, target: CGPoint(x: rect.maxX, y: rect.maxY), slop: slop) {
            return .corner(.br)
        }
        // Edges.
        if pointNear(pt, target: CGPoint(x: rect.midX, y: rect.minY), slop: slop) {
            return .edge(.top)
        }
        if pointNear(pt, target: CGPoint(x: rect.midX, y: rect.maxY), slop: slop) {
            return .edge(.bottom)
        }
        if pointNear(pt, target: CGPoint(x: rect.minX, y: rect.midY), slop: slop) {
            return .edge(.left)
        }
        if pointNear(pt, target: CGPoint(x: rect.maxX, y: rect.midY), slop: slop) {
            return .edge(.right)
        }
        // Body.
        if rect.contains(pt) { return .body }
        return nil
    }

    private func pointNear(_ p: NSPoint, target: CGPoint, slop: CGFloat) -> Bool {
        abs(p.x - target.x) <= slop && abs(p.y - target.y) <= slop
    }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        guard acceptsGeometryInput else { return }
        let pt = convert(event.locationInWindow, from: nil)
        activeGrab = hitTestHandle(at: pt)
        dragAnchor = pt
        dragOriginRect = cropRect
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard acceptsGeometryInput else { return }
        guard let anchor = dragAnchor,
              let origin = dragOriginRect,
              let grab = activeGrab else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let dx = pt.x - anchor.x
        let dy = pt.y - anchor.y
        let shiftLocked = event.modifierFlags.contains(.shift)

        let newRect: CGRect
        switch grab {
        case .body:
            newRect = moveRect(origin, by: CGVector(dx: dx, dy: dy))
        case .corner(let c):
            newRect = resizeCorner(origin, corner: c, dx: dx, dy: dy, shiftLocked: shiftLocked)
        case .edge(let e):
            newRect = resizeEdge(origin, edge: e, dx: dx, dy: dy, shiftLocked: shiftLocked)
        }
        cropRect = clamp(newRect, to: imageFrame)
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchor = nil
        dragOriginRect = nil
        activeGrab = nil
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // A hidden frame (another tool) never eats the arrows: they go
        // on to the window, which navigates. While a save or a question
        // runs, the arrows do nothing; Esc still gives the keyboard back
        // and every other key (Tab, Return) goes on.
        guard !isHiddenOrHasHiddenAncestor else {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags
        guard let command = CropKeyCommand.command(
            key: KeyCharacters.key(of: event), shift: flags.contains(.shift),
            option: flags.contains(.option), control: flags.contains(.control),
            command: flags.contains(.command)) else {
            super.keyDown(with: event)
            return
        }
        if case .done = command, !acceptsGeometryInput { super.keyDown(with: event); return }
        perform(command)
    }

    /// Runs a key command on the frame (also the entry point of the tests).
    func perform(_ command: CropKeyCommand) {
        switch command {
        case .done:
            onDone?()
        case .escape:
            onEscape?()
        case .move, .resize:
            guard acceptsGeometryInput, let pixels = integralPixelRect, imagePixelSize.width > 0,
                  let outcome = CropKeyGeometry.apply(command, to: pixels, in: imagePixelSize, aspect: aspectRatio) else { return }
            if outcome.rect != pixels { setRectFromImageSpace(outcome.rect) }
            announce(outcome.hitEdge ? CropKeyGeometry.edgeAnnouncement
                                     : CropKeyGeometry.valueText(outcome.rect))
        }
    }

    // MARK: - Accessibility

    /// Return: Done, not Apply.
    var onDone: (() -> Void)?
    /// Esc: focus goes back to the photo.
    var onEscape: (() -> Void)?
    /// Announcements posted (tests read it; the real post goes to VoiceOver).
    private(set) var announcementsForTesting: [String] = []
    private var announcementThrottle = AnnouncementThrottle(interval: CropKeyGeometry.announcementInterval)
    /// The clock of the throttle (tests move it).
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private func announce(_ text: String) {
        guard announcementThrottle.allow(at: uptime()) else { return }
        announcementsForTesting.append(text)
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { CropKeyGeometry.frameLabel }
    override func accessibilityHelp() -> String? { CropKeyGeometry.frameHelp }
    override func accessibilityValue() -> Any? {
        integralPixelRect.map(CropKeyGeometry.valueText)
    }
    override func accessibilityChildren() -> [Any]? { handleViews }

    /// The eight handle children, kept on the frame's handle points.
    private lazy var handleViews: [CropHandleView] = CropKeyGeometry.Handle.allCases.map { handle in
        let view = CropHandleView(handle: handle)
        view.onAdjust = { [weak self] grow in self?.adjust(handle, grow: grow) ?? false }
        view.valueProvider = { [weak self] in self?.integralPixelRect.map(CropKeyGeometry.valueText) }
        addSubview(view)
        return view
    }

    private func layoutHandleViews() {
        for view in handleViews { view.frame = handleFrame(view.handle) }
    }

    /// A handle moved by VoiceOver: grow (+1) or shrink (-1) by one pixel.
    func adjust(_ handle: CropKeyGeometry.Handle, grow: Int) -> Bool {
        guard acceptsGeometryInput, let pixels = integralPixelRect, imagePixelSize.width > 0 else { return false }
        let outcome = CropKeyGeometry.resize(pixels, in: imagePixelSize, edges: handle.edges(grow: grow),
                                             steps: 1, aspect: aspectRatio)
        if outcome.rect != pixels { setRectFromImageSpace(outcome.rect) }
        announce(outcome.hitEdge ? CropKeyGeometry.edgeAnnouncement : CropKeyGeometry.valueText(outcome.rect))
        return true
    }

    /// Where a handle sits, in this view's coordinates.
    func handleFrame(_ handle: CropKeyGeometry.Handle) -> CGRect {
        let rect = cropRect
        let center: CGPoint
        switch handle {
        case .topLeft: center = CGPoint(x: rect.minX, y: rect.minY)
        case .top: center = CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: center = CGPoint(x: rect.maxX, y: rect.minY)
        case .right: center = CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: center = CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: center = CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: center = CGPoint(x: rect.minX, y: rect.maxY)
        case .left: center = CGPoint(x: rect.minX, y: rect.midY)
        }
        return CGRect(x: center.x - handleSize / 2, y: center.y - handleSize / 2,
                      width: handleSize, height: handleSize)
    }

    /// The frame in whole image pixels (origin top-left), nil before a photo is set.
    var integralPixelRect: CGRect? {
        guard imageFrame.width > 0, imageFrame.height > 0,
              imagePixelSize.width > 0, imagePixelSize.height > 0 else { return nil }
        let sx = imagePixelSize.width / imageFrame.width
        let sy = imagePixelSize.height / imageFrame.height
        let x = ((cropRect.origin.x - imageFrame.origin.x) * sx).rounded()
        let y = ((cropRect.origin.y - imageFrame.origin.y) * sy).rounded()
        let right = ((cropRect.maxX - imageFrame.origin.x) * sx).rounded()
        let bottom = ((cropRect.maxY - imageFrame.origin.y) * sy).rounded()
        return CGRect(x: x, y: y, width: max(right - x, 1), height: max(bottom - y, 1))
    }

    var handleViewsForTesting: [CropHandleView] { handleViews }

    // MARK: - Geometry helpers

    private func moveRect(_ rect: CGRect, by vec: CGVector) -> CGRect {
        CGRect(
            x: rect.origin.x + vec.dx,
            y: rect.origin.y + vec.dy,
            width: rect.width,
            height: rect.height
        )
    }

    private func resizeCorner(
        _ rect: CGRect,
        corner: CornerHandle,
        dx: CGFloat,
        dy: CGFloat,
        shiftLocked: Bool
    ) -> CGRect {
        var r = rect
        switch corner {
        case .tl:
            r.origin.x += dx
            r.origin.y += dy
            r.size.width  -= dx
            r.size.height -= dy
        case .tr:
            r.origin.y += dy
            r.size.width  += dx
            r.size.height -= dy
        case .bl:
            r.origin.x += dx
            r.size.width  -= dx
            r.size.height += dy
        case .br:
            r.size.width  += dx
            r.size.height += dy
        }
        r = enforceMinSize(r)
        if let ratio = aspectRatio ?? (shiftLocked ? currentAspect() : nil) {
            r = lockAspect(r, ratio: ratio, anchor: corner)
        }
        return r
    }

    private func resizeEdge(
        _ rect: CGRect,
        edge: EdgeHandle,
        dx: CGFloat,
        dy: CGFloat,
        shiftLocked: Bool
    ) -> CGRect {
        var r = rect
        switch edge {
        case .top:
            r.origin.y += dy
            r.size.height -= dy
        case .bottom:
            r.size.height += dy
        case .left:
            r.origin.x += dx
            r.size.width -= dx
        case .right:
            r.size.width += dx
        }
        r = enforceMinSize(r)
        if let ratio = aspectRatio ?? (shiftLocked ? currentAspect() : nil) {
            r = lockAspectOnEdge(r, ratio: ratio, edge: edge)
        }
        return r
    }

    private func enforceMinSize(_ r: CGRect) -> CGRect {
        var out = r
        if out.width < 10 {
            out.size.width = 10
        }
        if out.height < 10 {
            out.size.height = 10
        }
        return out
    }

    private func currentAspect() -> Double? {
        guard cropRect.height > 0 else { return nil }
        return Double(cropRect.width) / Double(cropRect.height)
    }

    private func lockAspect(_ r: CGRect, ratio: Double, anchor: CornerHandle) -> CGRect {
        // Prefer the larger dimension as the driver.
        var out = r
        let widthFromHeight = CGFloat(ratio) * out.height
        let heightFromWidth = out.width / CGFloat(ratio)
        if out.width >= widthFromHeight {
            // Width drives; adjust height.
            let newHeight = heightFromWidth
            switch anchor {
            case .tl, .tr:
                out.origin.y += out.height - newHeight
            case .bl, .br:
                break
            }
            out.size.height = newHeight
        } else {
            // Height drives; adjust width.
            let newWidth = widthFromHeight
            switch anchor {
            case .tl, .bl:
                out.origin.x += out.width - newWidth
            case .tr, .br:
                break
            }
            out.size.width = newWidth
        }
        return out
    }

    private func lockAspectOnEdge(_ r: CGRect, ratio: Double, edge: EdgeHandle) -> CGRect {
        var out = r
        switch edge {
        case .top, .bottom:
            // Height changed; fix width symmetrically around current midX.
            let newWidth = CGFloat(ratio) * out.height
            let mid = out.midX
            out.origin.x = mid - newWidth / 2
            out.size.width = newWidth
        case .left, .right:
            // Width changed; fix height symmetrically around current midY.
            let newHeight = out.width / CGFloat(ratio)
            let mid = out.midY
            out.origin.y = mid - newHeight / 2
            out.size.height = newHeight
        }
        return out
    }

    private func clamp(_ r: CGRect, to container: CGRect) -> CGRect {
        guard container.width > 0, container.height > 0 else { return r }
        var out = r
        if out.size.width > container.width {
            out.size.width = container.width
        }
        if out.size.height > container.height {
            out.size.height = container.height
        }
        if out.minX < container.minX { out.origin.x = container.minX }
        if out.minY < container.minY { out.origin.y = container.minY }
        if out.maxX > container.maxX { out.origin.x = container.maxX - out.size.width }
        if out.maxY > container.maxY { out.origin.y = container.maxY - out.size.height }
        return out
    }

    // MARK: - Reporting

    /// Emit `onRectChanged` with the rect translated into image-pixel
    /// space. The panel converts this to `CropRect` via
    /// `CropTool.normalise(rect:in:)` at Apply time.
    private func notifyChanged() {
        guard imageFrame.width > 0, imageFrame.height > 0,
              imagePixelSize.width > 0, imagePixelSize.height > 0 else {
            onRectChanged?(.zero)
            return
        }
        let sx = Double(imagePixelSize.width)  / Double(imageFrame.width)
        let sy = Double(imagePixelSize.height) / Double(imageFrame.height)
        let pixelRect = CGRect(
            x: Double(cropRect.origin.x - imageFrame.origin.x) * sx,
            y: Double(cropRect.origin.y - imageFrame.origin.y) * sy,
            width:  Double(cropRect.width)  * sx,
            height: Double(cropRect.height) * sy
        )
        onRectChanged?(pixelRect)
    }

    // MARK: - Public API

    /// Reset the rect to cover the whole image.
    func resetToFull() {
        cropRect = imageFrame
    }

    /// Set the rect from an image-space pixel rect (used when the
    /// parameter panel types W/H).
    func setRectFromImageSpace(_ pixelRect: CGRect) {
        guard imageFrame.width > 0, imageFrame.height > 0,
              imagePixelSize.width > 0, imagePixelSize.height > 0 else { return }
        let sx = Double(imageFrame.width)  / Double(imagePixelSize.width)
        let sy = Double(imageFrame.height) / Double(imagePixelSize.height)
        let screenRect = CGRect(
            x: imageFrame.origin.x + CGFloat(Double(pixelRect.origin.x) * sx),
            y: imageFrame.origin.y + CGFloat(Double(pixelRect.origin.y) * sy),
            width:  CGFloat(Double(pixelRect.width)  * sx),
            height: CGFloat(Double(pixelRect.height) * sy)
        )
        cropRect = clamp(screenRect, to: imageFrame)
    }

    // MARK: - Test seams

    internal var _cropRect: CGRect { cropRect }
    internal var _imageFrame: CGRect { imageFrame }
}

/// One of the eight crop handles as VoiceOver sees it: a transparent child
/// view (role handle, a label, adjustable by one image pixel). It draws
/// nothing and never takes a click.
final class CropHandleView: NSView {
    let handle: CropKeyGeometry.Handle
    /// Grow (+1) or shrink (-1) by one image pixel; false when refused.
    var onAdjust: ((Int) -> Bool)?
    /// The frame's value text, read when VoiceOver asks.
    var valueProvider: (() -> String?)?

    init(handle: CropKeyGeometry.Handle) {
        self.handle = handle
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .handle }
    override func accessibilityLabel() -> String? { handle.label }
    override func accessibilityValue() -> Any? { valueProvider?() }
    override func accessibilityPerformIncrement() -> Bool { onAdjust?(1) ?? false }
    override func accessibilityPerformDecrement() -> Bool { onAdjust?(-1) ?? false }
}
