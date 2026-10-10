//
//  ContactSheetRenderer.swift
//  ShrikeEdit
//
//  File ▸ Export Contact Sheet…. A PDF of
//  thumbnails in a grid, one or more pages.
//
//  Layout (points, PDF space):
//    - 36 pt margins on every side.
//    - Title 14 pt semibold top-left; "Page N of M" 9 pt top-right. The
//      title band is the title line plus 10 pt.
//    - Square cells: width = (content width − (columns − 1) × 8) / columns.
//      The thumbnail is aspect-fitted and centred in its cell.
//    - Caption 7 pt, one line, middle truncation; its top sits 1 pt below
//      the cell.
//    - Row pitch = cell + 14 (cell + 8 without captions), so a caption's
//      bottom stays ≥ 3 pt above the next row's cell (a 7 pt line is 9 pt
//      tall). Rows per page = as many whole rows as fit under the title
//      band.
//    - A4, 5 columns: 98 pt cells, 6 rows (30 per page). 8 columns: 58 pt
//      cells, 10 rows (80 per page). US Letter, 5 columns: 101.6 pt cells,
//      5 rows (25 per page).
//
//  Thumbnails come from `ThumbnailCache` at `.nearby` priority, at ≥ 2
//  pixels per point (144 ppi). Pages are drawn one at a time while the
//  next page's thumbnails load; at most two pages of thumbnails are held.
//
//  Output is written to a hidden temp file in the destination folder and
//  renamed over `url` at the end. Cancelling the consuming task stops the
//  work and leaves no file behind.
//

import Foundation
import AppKit
import ShrikeCore
import CoreGraphics
import CoreText
import ShrikeCore

// MARK: - Options

public enum ContactSheetPaper: String, Sendable, CaseIterable, Codable {
    case a4
    case usLetter

    /// Page size in points.
    public var size: CGSize {
        switch self {
        case .a4: return CGSize(width: 595.28, height: 841.89)
        case .usLetter: return CGSize(width: 612, height: 792)
        }
    }
}

public enum ContactSheetCaption: String, Sendable, CaseIterable, Codable {
    case none
    case fileName
    case fileNameAndDate
}

public struct ContactSheetOptions: Sendable, Hashable {
    public static let columnRange = 3...8

    public var title: String
    /// 3…8; values outside are clamped.
    public var columns: Int {
        get { _columns }
        set { _columns = min(max(newValue, Self.columnRange.lowerBound), Self.columnRange.upperBound) }
    }
    public var paper: ContactSheetPaper
    public var caption: ContactSheetCaption
    private var _columns: Int = 5

    public init(title: String, columns: Int = 5,
                paper: ContactSheetPaper = ContactSheetOptions.defaultPaper(for: .current),
                caption: ContactSheetCaption = .fileName) {
        self.title = title
        self.paper = paper
        self.caption = caption
        self.columns = columns
    }

    /// US Letter for the Americas' letter countries, A4 otherwise (the
    /// list lives in `PrintSettings`, next to the stored paper setting).
    public static func defaultPaper(for locale: Locale) -> ContactSheetPaper {
        ContactSheetPaper(PrintSettings.defaultPaper(for: locale))
    }

    /// The Contact Sheet sheet's starting values from the stored print
    /// settings.
    public init(title: String, settings: PrintSettings) {
        self.init(title: title, columns: settings.contactSheetColumns,
                  paper: ContactSheetPaper(settings.contactSheetPaper),
                  caption: ContactSheetCaption(settings.contactSheetCaption))
    }
}

// MARK: - Stored settings bridge

public extension ContactSheetPaper {
    init(_ paper: PrintSettings.Paper) {
        switch paper {
        case .a4: self = .a4
        case .usLetter: self = .usLetter
        }
    }
}

public extension ContactSheetCaption {
    init(_ caption: PrintSettings.Caption) {
        switch caption {
        case .none: self = .none
        case .fileName: self = .fileName
        case .fileNameAndDate: self = .fileNameAndDate
        }
    }
}

public extension PrintSettings {
    /// Remembers what the user chose in the Contact Sheet sheet.
    mutating func remember(_ options: ContactSheetOptions) {
        contactSheetColumns = options.columns
        contactSheetPaper = options.paper == .a4 ? .a4 : .usLetter
        switch options.caption {
        case .none: contactSheetCaption = .none
        case .fileName: contactSheetCaption = .fileName
        case .fileNameAndDate: contactSheetCaption = .fileNameAndDate
        }
    }
}

// MARK: - Layout

/// The page arithmetic, separate from drawing so it can be tested.
public struct ContactSheetLayout: Sendable, Equatable {
    public static let margin: CGFloat = 36
    public static let gutter: CGFloat = 8
    public static let titleFontSize: CGFloat = 14
    public static let pageNumberFontSize: CGFloat = 9
    public static let captionFontSize: CGFloat = 7
    public static let titleGap: CGFloat = 10
    /// Space under a cell before the next row: the caption band.
    public static let captionBand: CGFloat = 14
    /// Space under a cell before the next row when there is no caption.
    public static let plainBand: CGFloat = 8
    /// The caption's top sits this far below its cell.
    public static let captionTopGap: CGFloat = 1

    public let pageSize: CGSize
    public let columns: Int
    public let cell: CGFloat
    public let rowPitch: CGFloat
    /// Title line height + 10 pt.
    public let titleBand: CGFloat
    public let rowsPerPage: Int
    public var perPage: Int { rowsPerPage * columns }

    public init(options: ContactSheetOptions) {
        pageSize = options.paper.size
        columns = options.columns
        let content = pageSize.width - 2 * Self.margin
        cell = (content - CGFloat(columns - 1) * Self.gutter) / CGFloat(columns)
        rowPitch = cell + (options.caption == .none ? Self.plainBand : Self.captionBand)
        titleBand = Self.lineHeight(ContactSheetFonts.title) + Self.titleGap
        let available = pageSize.height - 2 * Self.margin - titleBand
        rowsPerPage = max(1, Int((available / rowPitch).rounded(.down)))
    }

    public func pageCount(for items: Int) -> Int {
        max(1, (items + perPage - 1) / perPage)
    }

    /// Cell rectangle (PDF space, y-up) for slot `index` on a page.
    public func cellRect(at index: Int) -> CGRect {
        let row = index / columns, column = index % columns
        let gridTop = pageSize.height - Self.margin - titleBand
        return CGRect(x: Self.margin + CGFloat(column) * (cell + Self.gutter),
                      y: gridTop - CGFloat(row) * rowPitch - cell,
                      width: cell, height: cell)
    }

    /// Caption baseline (PDF space, y-up) under `cell`: the line's top sits
    /// `captionTopGap` below the cell.
    static func captionBaseline(below cell: CGRect, font: CTFont) -> CGFloat {
        cell.minY - captionTopGap - CTFontGetAscent(font)
    }

    /// Thumbnail pixel size: ≥ 2 px per point, rounded up to a multiple of
    /// 64 so sheets share cache entries with the grid's size steps.
    public var thumbnailPixelSize: Int {
        let minimum = Int((cell * 2).rounded(.up))
        return (minimum + 63) / 64 * 64
    }

    static func lineHeight(_ font: CTFont) -> CGFloat {
        (CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)).rounded(.up)
    }
}

/// Fonts are created per use: `CTFont` is immutable and thread-safe.
enum ContactSheetFonts {
    static var title: CTFont { NSFont.systemFont(ofSize: ContactSheetLayout.titleFontSize, weight: .semibold) }
    static var pageNumber: CTFont { NSFont.systemFont(ofSize: ContactSheetLayout.pageNumberFontSize) }
    static var caption: CTFont { NSFont.systemFont(ofSize: ContactSheetLayout.captionFontSize) }
}

// MARK: - Renderer

public enum ContactSheetError: Error, Sendable, Equatable {
    /// The PDF could not be created or moved into place.
    case cannotWrite
}

public enum ContactSheetRenderer {

    /// Renders `groups` (their primaries) to a PDF at `url`. Yields progress
    /// 0…1 and finishes after the file is in place. Cancel by cancelling
    /// the consuming task: no file is left.
    public static func render(_ groups: [ImageGroup], options: ContactSheetOptions,
                              thumbnails: ThumbnailCache, to url: URL) -> AsyncThrowingStream<Double, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await run(groups, options: options, thumbnails: thumbnails, to: url) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One page's worth of thumbnails and captions.
    private struct PageContent: Sendable {
        var images: [CGImage?]
        var captions: [String]
    }

    private static func run(_ groups: [ImageGroup], options: ContactSheetOptions,
                            thumbnails: ThumbnailCache, to url: URL,
                            progress: @Sendable (Double) -> Void) async throws {
        let layout = ContactSheetLayout(options: options)
        let pages = layout.pageCount(for: groups.count)
        progress(0)

        let folder = url.deletingLastPathComponent()
        let tmp = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        var mediaBox = CGRect(origin: .zero, size: layout.pageSize)
        let info: [CFString: Any] = [kCGPDFContextTitle: options.title, kCGPDFContextCreator: "Shrike"]
        guard let ctx = CGContext(tmp as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw ContactSheetError.cannotWrite
        }

        func slice(_ page: Int) -> [ImageGroup] {
            let start = page * layout.perPage
            return Array(groups[min(start, groups.count)..<min(start + layout.perPage, groups.count)])
        }
        func load(_ page: Int) -> Task<PageContent, Never> {
            let items = slice(page)
            let size = layout.thumbnailPixelSize
            let caption = options.caption
            return Task(priority: .userInitiated) {
                await loadPage(items, pixelSize: size, caption: caption, thumbnails: thumbnails)
            }
        }

        var next: Task<PageContent, Never>? = load(0)
        do {
            for page in 0..<pages {
                guard let current = next else { break }
                let content = await withTaskCancellationHandler {
                    await current.value
                } onCancel: {
                    current.cancel()
                }
                try Task.checkCancellation()
                next = page + 1 < pages ? load(page + 1) : nil
                draw(page: page, of: pages, content: content, layout: layout, title: options.title, in: ctx)
                progress(Double(page + 1) / Double(pages) * 0.99)
            }
            ctx.closePDF()
            try Task.checkCancellation()
            guard rename(tmp.path, url.path) == 0 else { throw ContactSheetError.cannotWrite }
            progress(1)
        } catch {
            next?.cancel()
            ctx.closePDF()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    private static func loadPage(_ items: [ImageGroup], pixelSize: Int, caption: ContactSheetCaption,
                                 thumbnails: ThumbnailCache) async -> PageContent {
        await withTaskGroup(of: (Int, CGImage?, String).self) { group in
            for (i, item) in items.enumerated() {
                group.addTask {
                    let image = try? await thumbnails.thumbnail(for: FileImageSource(url: item.primary),
                                                               maxPixelSize: pixelSize, priority: .nearby)
                    let text = await captionText(for: item.primary, caption: caption)
                    return (i, image, text)
                }
            }
            var content = PageContent(images: Array(repeating: nil, count: items.count),
                                      captions: Array(repeating: "", count: items.count))
            for await (i, image, text) in group {
                content.images[i] = image
                content.captions[i] = text
            }
            return content
        }
    }

    static func captionText(for url: URL, caption: ContactSheetCaption) async -> String {
        switch caption {
        case .none: return ""
        case .fileName: return url.lastPathComponent
        case .fileNameAndDate:
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            var date: Date?
            if let info = try? await PhotoInfo.read(url), let taken = info.dateTaken {
                date = taken
                formatter.timeZone = info.dateTakenTimeZone
            } else {
                date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            guard let date else { return url.lastPathComponent }
            return "\(url.lastPathComponent) · \(formatter.string(from: date))"
        }
    }

    // MARK: Drawing

    private static func draw(page: Int, of pages: Int, content: PageContent, layout: ContactSheetLayout,
                             title: String, in ctx: CGContext) {
        ctx.beginPDFPage(nil)
        let size = layout.pageSize
        let top = size.height - ContactSheetLayout.margin
        let left = ContactSheetLayout.margin, right = size.width - ContactSheetLayout.margin
        let black = CGColor(gray: 0, alpha: 1)

        let pageText = "Page \(page + 1) of \(pages)"
        let pageLine = line(pageText, font: ContactSheetFonts.pageNumber, color: black)
        let pageWidth = CGFloat(CTLineGetTypographicBounds(pageLine, nil, nil, nil))
        let titleFont = ContactSheetFonts.title
        if !title.isEmpty {
            let titleLine = truncated(line(title, font: titleFont, color: black),
                                      width: right - left - pageWidth - 12, font: titleFont, color: black)
            ctx.textPosition = CGPoint(x: left, y: top - CTFontGetAscent(titleFont))
            CTLineDraw(titleLine, ctx)
        }
        ctx.textPosition = CGPoint(x: right - pageWidth, y: top - CTFontGetAscent(titleFont))
        CTLineDraw(pageLine, ctx)

        let captionFont = ContactSheetFonts.caption
        for (i, image) in content.images.enumerated() {
            let cell = layout.cellRect(at: i)
            if let image {
                let w = CGFloat(image.width), h = CGFloat(image.height)
                let scale = min(cell.width / w, cell.height / h)
                let fitted = CGRect(x: cell.midX - w * scale / 2, y: cell.midY - h * scale / 2,
                                    width: w * scale, height: h * scale)
                ctx.saveGState()
                ctx.interpolationQuality = .high
                ctx.draw(image, in: fitted)
                ctx.restoreGState()
            } else {
                ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
                ctx.fill(cell)
            }
            let text = content.captions[i]
            if !text.isEmpty {
                let captionLine = truncated(line(text, font: captionFont, color: black),
                                            width: cell.width, font: captionFont, color: black)
                let width = CGFloat(CTLineGetTypographicBounds(captionLine, nil, nil, nil))
                ctx.textPosition = CGPoint(x: cell.midX - width / 2,
                                           y: ContactSheetLayout.captionBaseline(below: cell, font: captionFont))
                CTLineDraw(captionLine, ctx)
            }
        }
        ctx.endPDFPage()
    }

    private static func line(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    /// One line, middle truncation ("IMG_00…123.jpg").
    private static func truncated(_ line: CTLine, width: CGFloat, font: CTFont, color: CGColor) -> CTLine {
        guard CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > width else { return line }
        let token = self.line("…", font: font, color: color)
        return CTLineCreateTruncatedLine(line, Double(max(0, width)), .middle, token) ?? line
    }
}
