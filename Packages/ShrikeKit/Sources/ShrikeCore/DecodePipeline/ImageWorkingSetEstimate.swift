import Foundation

public struct ImageWorkingSetEstimate: Sendable {
    public let sourceBytes: Int
    public let outputBytes: Int
    public let totalBytes: Int
    public init(width: Int, height: Int, bitsPerComponent: Int = 8, floatingPoint: Bool = false,
                outputWidth: Int? = nil, outputHeight: Int? = nil, compressedBytes: Int = 0) throws {
        guard width > 0, height > 0, bitsPerComponent > 0, compressedBytes >= 0 else { throw ImageResourceError.invalidByteCount }
        let bpp = floatingPoint ? 16 : bitsPerComponent > 8 ? 8 : 4
        func product(_ values: Int...) throws -> Int {
            try values.reduce(1) { total, value in
                guard value > 0 else { throw ImageResourceError.invalidByteCount }
                let (result, overflow) = total.multipliedReportingOverflow(by: value)
                guard !overflow else { throw ImageResourceError.dimensionOverflow }; return result
            }
        }
        sourceBytes = try product(width, height, bpp)
        outputBytes = try product(outputWidth ?? width, outputHeight ?? height, bpp)
        let intermediate = try product(sourceBytes, 4)
        let (withOutput, a) = intermediate.addingReportingOverflow(outputBytes)
        let (total, b) = withOutput.addingReportingOverflow(compressedBytes)
        guard !a, !b else { throw ImageResourceError.dimensionOverflow }
        totalBytes = total
    }
}
