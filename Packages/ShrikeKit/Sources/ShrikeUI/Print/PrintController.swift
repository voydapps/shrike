//
//  PrintController.swift
//  ShrikeUI
//
//  File ▸ Print… and Page Setup…. The viewer prints the
//  shown photo, the Browser the selection, one photo per page, through
//  `NSPrintOperation` with the shared `NSPrintInfo`, the print panel with
//  its preview, and a hosted SwiftUI accessory (Scaling, file name).
//
//  * The panel shows at once. Pixels come from the full-resolution,
//    oriented, uncached output decode (`OutputDecoder`),
//    in the file's colour space, never on the main thread. While a page
//    is still decoding the preview shows its name; the preview redraws
//    when the pixels land. The real print waits for them.
//  * The page orientation follows the (first) photo; the user can still
//    change it in the panel.
//

import AppKit
import SwiftUI
import ImageIO
import os
import ShrikeCore

// MARK: - Page geometry (pure)

/// One photo to print: its file and what its header says.
struct PrintPage: Sendable, Equatable {
    let url: URL
    let name: String
    /// Pixel size after EXIF orientation; nil when unreadable.
    let pixelSize: CGSize?
    /// `kCGImagePropertyDPIWidth`; nil when missing.
    let dpi: Double?

    /// Reads the header (file I/O: never on the main thread).
    static func read(_ url: URL) -> PrintPage {
        let info = try? PhotoInfo.readSync(url)
        return PrintPage(url: url, name: url.lastPathComponent, pixelSize: info?.pixelSize, dpi: info?.dpi)
    }
}

enum PrintLayout {

    /// Ink-free edge kept on every side, even on a borderless printer.
    static let minimumMargin: CGFloat = 18
    /// "Print file name under the image": one 9 pt line under it.
    static let nameFontSize: CGFloat = 9
    static let nameLineHeight: CGFloat = 18
    /// Actual size without a DPI in the file.
    static let fallbackPPI: Double = 300

    /// Landscape photo → landscape page; square and portrait → portrait.
    static func orientation(for pixelSize: CGSize?) -> NSPrintInfo.PaperOrientation {
        guard let size = pixelSize else { return .portrait }
        return size.width > size.height ? .landscape : .portrait
    }

    /// The part of a page's content for the photo (the name line is cut
    /// off the bottom when it is on). `content` is in a flipped view.
    static func imageArea(content: CGRect, showFileName: Bool) -> CGRect {
        guard showFileName else { return content }
        var area = content
        area.size.height = max(0, area.height - nameLineHeight)
        return area
    }

    /// Where the photo is drawn: Fit = largest inside `area`; Fill =
    /// covers it (the caller clips, a centred crop); Actual size = the
    /// file's DPI (300 ppi when missing), centred (clipped when larger).
    static func imageRect(pixelSize: CGSize, dpi: Double?, scaling: PrintSettings.Scaling,
                          in area: CGRect) -> CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0, area.width > 0, area.height > 0 else { return .zero }
        let scale: CGFloat
        switch scaling {
        case .fit: scale = min(area.width / pixelSize.width, area.height / pixelSize.height)
        case .fill: scale = max(area.width / pixelSize.width, area.height / pixelSize.height)
        case .actual:
            let ppi = (dpi ?? 0) > 0 ? dpi! : fallbackPPI
            scale = CGFloat(72 / ppi)
        }
        let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

// MARK: - Decoded pixels (shared with the decode threads)

/// The decoded photos by page. The decode tasks fill it off the main
/// thread; the print view reads it, and the real print waits on it.
final class PrintImageStore: Sendable {
    private enum Slot: Sendable { case image(CGImage), failed }
    private let slots = OSAllocatedUnfairLock<[Int: Slot]>(initialState: [:])
    private let signals: [DispatchSemaphore]

    init(count: Int) {
        signals = (0..<count).map { _ in DispatchSemaphore(value: 0) }
    }

    func set(_ image: CGImage?, at index: Int) {
        guard signals.indices.contains(index) else { return }
        slots.withLock { $0[index] = image.map(Slot.image) ?? .failed }
        signals[index].signal()
    }

    /// nil = still decoding or failed.
    func image(at index: Int) -> CGImage? {
        slots.withLock { if case .image(let image)? = $0[index] { return image } else { return nil } }
    }

    func isDone(_ index: Int) -> Bool { slots.withLock { $0[index] != nil } }

    /// Blocks until page `index` is decoded (or failed) or `timeout` ends.
    func wait(for index: Int, timeout: TimeInterval) -> CGImage? {
        guard signals.indices.contains(index) else { return nil }
        if isDone(index) { return image(at: index) }
        if signals[index].wait(timeout: .now() + timeout) == .success {
            signals[index].signal()   // later waiters pass too
        }
        return image(at: index)
    }
}

// MARK: - The print view

/// One photo per page, drawn per `PrintSettings`.
@MainActor
final class PrintPagesView: NSView {

    let pages: [PrintPage]
    let store: PrintImageStore
    var scaling: PrintSettings.Scaling = .fit
    var showFileName = false
    /// The print info used outside a print operation (tests).
    var fallbackPrintInfo: NSPrintInfo
    /// True while the print panel (and its preview) is on screen: a page
    /// still decoding draws its name instead of waiting.
    var isPreviewing: () -> Bool = { false }

    init(pages: [PrintPage], store: PrintImageStore, printInfo: NSPrintInfo) {
        self.pages = pages
        self.store = store
        self.fallbackPrintInfo = printInfo
        super.init(frame: .zero)
        setFrameSize(NSSize(width: pageSize.width, height: pageSize.height * CGFloat(max(1, pages.count))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var printInfo: NSPrintInfo { NSPrintOperation.current?.printInfo ?? fallbackPrintInfo }

    /// The page's content size: the paper less the margins.
    var pageSize: CGSize {
        let info = printInfo
        let paper = info.paperSize
        return CGSize(width: max(1, paper.width - info.leftMargin - info.rightMargin),
                      height: max(1, paper.height - info.topMargin - info.bottomMargin))
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        let size = pageSize
        setFrameSize(NSSize(width: size.width, height: size.height * CGFloat(max(1, pages.count))))
        range.pointee = NSRange(location: 1, length: pages.count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        let size = pageSize
        return NSRect(x: 0, y: CGFloat(page - 1) * size.height, width: size.width, height: size.height)
    }

    /// Where page `index` (0-based) draws its photo, in view coordinates.
    func imageRect(forPage index: Int) -> CGRect? {
        guard pages.indices.contains(index), let size = pixelSize(forPage: index) else { return nil }
        let area = PrintLayout.imageArea(content: rectForPage(index + 1), showFileName: showFileName)
        return PrintLayout.imageRect(pixelSize: size, dpi: pages[index].dpi, scaling: scaling, in: area)
    }

    private func pixelSize(forPage index: Int) -> CGSize? {
        if let image = store.image(at: index) { return CGSize(width: image.width, height: image.height) }
        return pages[index].pixelSize
    }

    override func draw(_ dirtyRect: NSRect) {
        for index in pages.indices {
            let page = rectForPage(index + 1)
            guard page.intersects(dirtyRect) else { continue }
            drawPage(index, in: page)
        }
    }

    private func drawPage(_ index: Int, in page: CGRect) {
        let area = PrintLayout.imageArea(content: page, showFileName: showFileName)
        var image = store.image(at: index)
        if image == nil, !store.isDone(index), !isPreviewing() {
            image = store.wait(for: index, timeout: 60)
        }
        if let image, let rect = imageRect(forPage: index) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: area).addClip()
            let picture = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            picture.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
        } else {
            // Still decoding (preview) or unreadable: the name, centred.
            drawName(pages[index].name, centredIn: area, color: .secondaryLabelColor, size: 11)
        }
        if showFileName {
            let line = CGRect(x: page.minX, y: area.maxY, width: page.width, height: PrintLayout.nameLineHeight)
            drawName(pages[index].name, centredIn: line, color: .black, size: PrintLayout.nameFontSize)
        }
    }

    private func drawName(_ name: String, centredIn rect: CGRect, color: NSColor, size: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: style,
        ]
        let text = name as NSString
        let height = text.size(withAttributes: attributes).height
        text.draw(in: CGRect(x: rect.minX + 4, y: rect.midY - height / 2, width: max(0, rect.width - 8), height: height),
                  withAttributes: attributes)
    }
}

// MARK: - Accessory (hosted SwiftUI)

@MainActor
final class PrintAccessoryModel: ObservableObject {
    @Published var scaling: PrintSettings.Scaling { didSet { onChange?() } }
    @Published var showFileName: Bool { didSet { onChange?() } }
    var onChange: (() -> Void)?

    init(settings: PrintSettings) {
        scaling = settings.scaling
        showFileName = settings.showFileName
    }
}

struct PrintAccessoryView: View {
    @ObservedObject var model: PrintAccessoryModel

    var body: some View {
        Form {
            Picker("Scaling:", selection: $model.scaling) {
                Text("Fit to page").tag(PrintSettings.Scaling.fit)
                Text("Fill page (crops)").tag(PrintSettings.Scaling.fill)
                Text("Actual size").tag(PrintSettings.Scaling.actual)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            Toggle("Print file name under the photo", isOn: $model.showFileName)
        }
        .padding(16)
        .fixedSize()
    }
}

/// The panel's Shrike section. Its KVO keys redraw the preview.
@MainActor
final class PrintAccessoryController: NSViewController, NSPrintPanelAccessorizing {

    let model: PrintAccessoryModel
    /// Bumped when a page's pixels land: the preview redraws.
    @objc dynamic var revision = 0
    @objc dynamic var scalingValue: String
    @objc dynamic var showsFileName: Bool
    private(set) var isShowing = false

    init(model: PrintAccessoryModel) {
        self.model = model
        scalingValue = model.scaling.rawValue
        showsFileName = model.showFileName
        super.init(nibName: nil, bundle: nil)
        title = "Shrike"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let host = NSHostingView(rootView: PrintAccessoryView(model: model))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        view = host
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        isShowing = true
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        isShowing = false
    }

    func settingsChanged() {
        scalingValue = model.scaling.rawValue
        showsFileName = model.showFileName
    }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        let scaling: String
        switch model.scaling {
        case .fit: scaling = "Fit to page"
        case .fill: scaling = "Fill page (crops)"
        case .actual: scaling = "Actual size"
        }
        return [
            [.itemName: "Scaling", .itemDescription: scaling],
            [.itemName: "File name", .itemDescription: model.showFileName ? "On" : "Off"],
        ]
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> {
        ["revision", "scalingValue", "showsFileName"]
    }
}

// MARK: - The job

@MainActor
final class PrintController: NSObject {

    /// Tests build the job and never run the panel.
    nonisolated(unsafe) static var presentsPanels = true
    private(set) static var lastForTesting: PrintController?
    /// Jobs whose panel is up (the operation doesn't keep us alive).
    private static var running: [PrintController] = []

    let pages: [PrintPage]
    let printInfo: NSPrintInfo
    let store: PrintImageStore
    let view: PrintPagesView
    let accessory: PrintAccessoryController
    private let settingsStore: PrintSettingsStore
    private var decodes: [Task<Void, Never>] = []

    /// Reads the headers off the main thread, then shows the panel.
    static func start(urls: [URL], window: NSWindow?, settingsStore: PrintSettingsStore = .standard) {
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            let pages = await Task.detached(priority: .userInitiated) { urls.map(PrintPage.read) }.value
            let controller = PrintController(pages: pages, printInfo: NSPrintInfo.shared, settingsStore: settingsStore)
            lastForTesting = controller
            controller.decodeAll()
            if presentsPanels { controller.run(on: window) }
        }
    }

    /// File ▸ Page Setup… on the shared print info.
    static func runPageSetup(on window: NSWindow?) {
        let layout = NSPageLayout()
        if let window {
            layout.beginSheet(using: NSPrintInfo.shared, on: window, completionHandler: nil)
        } else {
            layout.runModal(with: NSPrintInfo.shared)
        }
    }

    init(pages: [PrintPage], printInfo: NSPrintInfo, settingsStore: PrintSettingsStore = .standard) {
        self.pages = pages
        self.printInfo = printInfo
        self.settingsStore = settingsStore
        let settings = settingsStore.load()
        store = PrintImageStore(count: pages.count)
        Self.configure(printInfo, for: pages)
        view = PrintPagesView(pages: pages, store: store, printInfo: printInfo)
        view.scaling = settings.scaling
        view.showFileName = settings.showFileName
        accessory = PrintAccessoryController(model: PrintAccessoryModel(settings: settings))
        super.init()
        let accessory = self.accessory
        view.isPreviewing = { [weak accessory] in accessory?.isShowing ?? false }
        accessory.model.onChange = { [weak self] in self?.settingsChanged() }
    }

    /// Orientation from the first photo; margins at the printable area
    /// (at least 18 pt); the page centred.
    static func configure(_ info: NSPrintInfo, for pages: [PrintPage]) {
        info.orientation = PrintLayout.orientation(for: pages.first?.pixelSize)
        let paper = info.paperSize
        let printable = info.imageablePageBounds
        let minimum = PrintLayout.minimumMargin
        info.leftMargin = max(minimum, printable.minX)
        info.bottomMargin = max(minimum, printable.minY)
        info.rightMargin = max(minimum, paper.width - printable.maxX)
        info.topMargin = max(minimum, paper.height - printable.maxY)
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
    }

    private func settingsChanged() {
        let model = accessory.model
        view.scaling = model.scaling
        view.showFileName = model.showFileName
        view.needsDisplay = true
        settingsStore.update {
            $0.scaling = model.scaling
            $0.showFileName = model.showFileName
        }
        accessory.settingsChanged()
    }

    /// Full-resolution output decodes, two at a time, off the main thread.
    func decodeAll() {
        let store = self.store
        let items = Array(pages.enumerated())
        let lanes = 2
        for lane in 0..<min(lanes, items.count) {
            let mine = items.filter { $0.offset % lanes == lane }
            decodes.append(Task.detached(priority: .userInitiated) { [weak self] in
                for (index, page) in mine {
                    if Task.isCancelled { store.set(nil, at: index); continue }
                    let image = try? await OutputDecoder.decode(url: page.url)
                    store.set(image, at: index)
                    await self?.pageDecoded()
                }
            })
        }
    }

    private func pageDecoded() {
        view.needsDisplay = true
        accessory.revision &+= 1
    }

    /// Waits for every decode (tests).
    func waitForDecodes() async {
        for task in decodes { await task.value }
    }

    func run(on window: NSWindow?) {
        let operation = NSPrintOperation(view: view, printInfo: printInfo)
        operation.jobTitle = pages.count == 1 ? pages[0].name : "\(pages.count) photos"
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.canSpawnSeparateThread = false
        let panel = operation.printPanel
        panel.options.insert([.showsPreview, .showsPaperSize, .showsOrientation, .showsCopies, .showsPageRange])
        panel.addAccessoryController(accessory)
        Self.running.append(self)
        if let window {
            operation.runModal(for: window, delegate: self,
                               didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        } else {
            operation.run()
            finish()
        }
    }

    @objc nonisolated func printOperationDidRun(_ operation: NSPrintOperation, success: Bool,
                                                contextInfo: UnsafeMutableRawPointer?) {
        Task { @MainActor [weak self] in self?.finish() }
    }

    private func finish() {
        for task in decodes { task.cancel() }
        Self.running.removeAll { $0 === self }
    }
}

// MARK: - Entry points

extension ViewerWindow {
    /// File ▸ Print…: the shown photo.
    func printDisplayed() {
        guard let url = displayedItem?.group.primary else { return }
        PrintController.start(urls: [url], window: self)
    }
}

extension BrowserWindowController {
    /// File ▸ Print…: the selection, one photo per page, in grid order.
    func printSelection() {
        let urls = contentController.selectedItems.map(\.group.primary)
        PrintController.start(urls: urls, window: window)
    }
}
