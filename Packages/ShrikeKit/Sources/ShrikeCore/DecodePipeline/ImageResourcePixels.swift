import CoreGraphics
import Foundation

extension ImageResourceBudget {
    public func retain(image: CGImage, owner: ImageResourceOwner, category: ImageResourceCategory,
                       isLazy: Bool = false) -> ImageResourceLease {
        if LazyOrientedPixels.attachAccounting(to: image, resources: self, owner: owner, category: category) {
            // This provider owns the future allocation and its accounting
            // lease; the image/queue token must not erase that charge.
            return retain([], owner: owner, category: category)
        }
        let (rowBytes, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        // ImageIO's private lazy provider exposes no materialization
        // callback. Charge its potential CPU allocation conservatively.
        return retain([ImageResourceCost(identity: .init(object: image, kind: .cpuPixels),
            bytes: overflow ? .max : rowBytes, isConservativeEstimate: isLazy)], owner: owner, category: category)
    }
}

extension DecodedImage {
    func retaining(in resources: ImageResourceBudget, owner: ImageResourceOwner,
                   category: ImageResourceCategory) -> DecodedImage {
        DecodedImage(sourceID: sourceID, image: image, prepared: prepared, requestedLongEdge: requestedLongEdge,
                     imageIsLazy: imageIsLazy,
                     resourceLease: resources.retain(image: image, owner: owner, category: category, isLazy: imageIsLazy))
    }
}

extension DecodeQueue {
    static func workingSet(for source: any ImageSource, target: Int?) async throws -> Int {
        let props = try? await source.loadProperties()
        var w = props?.pixelWidth ?? target ?? 4096
        var h = props?.pixelHeight ?? target ?? 4096
        guard w > 0, h > 0 else { throw ImageResourceError.invalidByteCount }
        if let target {
            let (doubleTarget, overflow) = target.multipliedReportingOverflow(by: 2)
            guard target > 0, !overflow else { throw ImageResourceError.dimensionOverflow }
            let scale = min(1, Double(doubleTarget) / Double(max(w, h)))
            w = max(1, Int((Double(w) * scale).rounded(.up)))
            h = max(1, Int((Double(h) * scale).rounded(.up)))
        }
        return try ImageWorkingSetEstimate(width: w, height: h, bitsPerComponent: props?.bitDepth ?? 8,
                                            floatingPoint: (props?.bitDepth ?? 8) > 16).totalBytes
    }
}
