//
//  LoupeView.swift
//  ShrikeUI
//
//  Circular magnifier loupe activated by holding the `Z` key.
//  source pixels at 2× (configurable). Simple CGImage crop + mask approach;
//  no separate CAMetalLayer.
//

import AppKit
import CoreGraphics

@MainActor
final class LoupeView: NSView {

    private static let diameter: CGFloat = 220
    private static let borderWidth: CGFloat = 2.0

    /// CGImage being magnified.
    var sourceImage: CGImage?

    /// Where the viewer draws the image, in the host view's coordinates
    /// (`MetalImageView.drawnImageRect`: follows zoom, pan and the turn).
    var drawnRect: CGRect = .zero

    /// The viewer's view-only turn (clockwise, a multiple of 90) and
    /// mirrors, as `MetalImageView` applies them: mirror first, then turn
    /// (the loupe used to show the pixels unturned).
    var rotationDegrees: Double = 0
    var flippedHorizontally = false
    var flippedVertically = false

    /// User-configurable magnification.
    var zoomFactor: CGFloat = 2.0

    /// Cursor position in the host view's coordinate space.
    private var cursorPoint: NSPoint = .zero

    private let imageLayer = CALayer()
    private let borderLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        let size = NSRect(
            x: 0, y: 0, width: Self.diameter, height: Self.diameter
        )
        super.init(frame: size)
        wantsLayer = true
        layer?.cornerRadius = Self.diameter / 2
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
        layer?.borderWidth = Self.borderWidth
        layer?.backgroundColor = NSColor.black.cgColor

        imageLayer.frame = bounds
        imageLayer.contentsGravity = .resizeAspectFill
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    func updateCursor(at point: NSPoint) {
        cursorPoint = point
        // Re-center loupe on cursor (slightly offset so the cursor is visible).
        let halfDim = Self.diameter / 2
        setFrameOrigin(NSPoint(
            x: point.x - halfDim,
            y: point.y - halfDim
        ))
        redrawContents()
    }

    private func redrawContents() {
        guard let source = sourceImage, source.width > 0, source.height > 0,
              let center = Self.sourcePoint(
                  forViewPoint: cursorPoint, drawnRect: drawnRect,
                  imageSize: CGSize(width: source.width, height: source.height),
                  rotationDegrees: rotationDegrees,
                  flippedH: flippedHorizontally, flippedV: flippedVertically)
        else {
            imageLayer.contents = nil
            return
        }
        // A square of diameter / zoomFactor source pixels, shown 220 pt wide.
        let side = max(1, Int((Self.diameter / zoomFactor).rounded()))
        imageLayer.contents = Self.makePatch(
            source: source, center: center, side: side,
            rotationDegrees: rotationDegrees,
            flippedH: flippedHorizontally, flippedV: flippedVertically)
    }

    /// The patch on screen now (tests).
    var patchForTesting: CGImage? {
        guard let contents = imageLayer.contents else { return nil }
        return (contents as! CGImage)
    }

    // MARK: Geometry (the inverse of `MetalImageView.buildTransform`)

    /// The source pixel (top-left origin) under `point`. The viewer maps
    /// the texture's [-1, 1] quad (y up, u = 0 on the left, v = 0 at the
    /// top) by mirror, then a clockwise turn, then scales it onto
    /// `drawnRect`; this walks that back. Nil when nothing is drawn.
    nonisolated static func sourcePoint(forViewPoint point: CGPoint, drawnRect: CGRect,
                                        imageSize: CGSize, rotationDegrees: Double,
                                        flippedH: Bool, flippedV: Bool) -> CGPoint? {
        guard drawnRect.width > 0, drawnRect.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return nil }
        let nx = (point.x - drawnRect.minX) / drawnRect.width * 2 - 1
        let ny = (point.y - drawnRect.minY) / drawnRect.height * 2 - 1
        // Undo the clockwise turn: turn counter-clockwise.
        let theta = rotationDegrees * .pi / 180
        let c = cos(theta), s = sin(theta)
        var tx = c * nx - s * ny
        var ty = s * nx + c * ny
        if flippedH { tx = -tx }
        if flippedV { ty = -ty }
        return CGPoint(x: (tx + 1) / 2 * imageSize.width,
                       y: (1 - ty) / 2 * imageSize.height)
    }

    /// A `side`-pixel square of `source` around `center` (top-left
    /// origin), turned and mirrored as the viewer shows it. One patch pixel
    /// is one source pixel; outside the image is black.
    nonisolated static func makePatch(source: CGImage, center: CGPoint, side: Int,
                                      rotationDegrees: Double, flippedH: Bool, flippedV: Bool) -> CGImage? {
        let width = CGFloat(source.width), height = CGFloat(source.height)
        // Turns are quarter turns, so the source area is the same square.
        let half = CGFloat(side) / 2
        let area = CGRect(x: center.x - half, y: center.y - half,
                          width: CGFloat(side), height: CGFloat(side))
            .integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        let wide = source.bitsPerComponent > 8
        // 8-bit photos keep their own space; deeper ones (HDR) go through
        // extended linear sRGB, which a half-float context always takes.
        let space: CGColorSpace
        if !wide, let own = source.colorSpace, own.model == .rgb, own.supportsOutput {
            space = own
        } else {
            space = CGColorSpace(name: wide ? CGColorSpace.extendedLinearSRGB : CGColorSpace.sRGB)!
        }
        let info: UInt32 = wide
            ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: wide ? 16 : 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard !area.isNull, area.width >= 1, area.height >= 1,
              let crop = source.cropping(to: area) else { return ctx.makeImage() }
        ctx.interpolationQuality = .none
        // Screen offset (y up) = turn(mirror(source offset)), around the
        // patch centre. Source y-up: y = height - top-origin y.
        ctx.translateBy(x: half, y: half)
        let mirror = CGAffineTransform(scaleX: flippedH ? -1 : 1, y: flippedV ? -1 : 1)
        let turn = CGAffineTransform(rotationAngle: -CGFloat(rotationDegrees) * .pi / 180)
        ctx.concatenate(mirror.concatenating(turn))
        ctx.translateBy(x: -center.x, y: -(height - center.y))
        ctx.draw(crop, in: CGRect(x: area.minX, y: height - area.maxY,
                                  width: area.width, height: area.height))
        return ctx.makeImage()
    }
}
