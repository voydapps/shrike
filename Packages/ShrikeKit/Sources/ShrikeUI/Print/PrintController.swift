//
//  PrintController.swift
//  ShrikeUI
//
//  File ▸ Print… and Page Setup…. The viewer prints the
//  shown photo, the Browser the selection, one photo per page, through
//  `NSPrintOperation` with the shared `NSPrintInfo`, the print panel with
//  its preview, and a hosted SwiftUI accessory (Scaling, file name).
//
//  * The photos load before the panel opens: pixels
//    come from the full-resolution, oriented, uncached output decode
//    (`OutputDecoder`), in the file's colour space, never on the main
//    thread, and the main thread never waits for them. After 300 ms a
//    "Getting photos ready" sheet shows progress and Cancel. A photo not
//    loaded within 60 s of the previous one prints as an empty frame with its name.
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
/// thread; the print view reads it; the main thread never waits on it.
final class PrintImageStore: Sendable {
    private enum Slot: Sendable { case image(CGImage), failed }
    private let slots = OSAllocatedUnfairLock<[Int: Slot]>(initialState: [:])

    init(count: Int) {}

    func set(_ image: CGImage?, at index: Int) {
        slots.withLock { $0[index] = image.map(Slot.image) ?? .failed }
    }

    /// nil = still decoding or failed.
    func image(at index: Int) -> CGImage? {
        slots.withLock { if case .image(let image)? = $0[index] { return image } else { return nil } }
    }

    func isDone(_ index: Int) -> Bool { slots.withLock { $0[index] != nil } }
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
        // The main thread never waits here. The photos
        // are loaded before the panel opens; one that did not load in time
        // prints as an empty frame with its name.
        let image = store.image(at: index)
        if let image, let rect = imageRect(forPage: index) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: area).addClip()
            let picture = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            picture.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
        } else {
            // Not loaded (still decoding, timed out or unreadable): an empty frame with the name.
            if !isPreviewing() {
                NSColor.gray.setStroke()
                let frame = NSBezierPath(rect: area.insetBy(dx: 0.5, dy: 0.5))
                frame.lineWidth = 1
                frame.stroke()
            }
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
    /// The window the panel runs on (the "couldn't be loaded" toast goes there).
    weak var hostWindow: NSWindow?

    /// Reads the headers off the main thread, then shows the panel.
    static func start(urls: [URL], window: NSWindow?, settingsStore: PrintSettingsStore = .standard) {
        guard !urls.isEmpty else { return }
        let hadWindow = window != nil
        Task { @MainActor [weak window] in
            let pages = await Task.detached(priority: .userInitiated) { urls.map(PrintPage.read) }.value
            let controller = PrintController(pages: pages, printInfo: NSPrintInfo.shared, settingsStore: settingsStore)
            lastForTesting = controller
            controller.decodeAll()
            guard presentsPanels else { return }
            guard await controller.prepare(on: window) else { controller.finish(); return }
            // The window was closed while the photos got ready: nothing runs.
            guard canRun(hadWindow: hadWindow, window: window) else { controller.finish(); return }
            controller.hostWindow = window
            controller.run(on: window)
        }
    }

    /// Started without a window (free-standing panel), or its window is
    /// still open (minimised or the app hidden counts as open).
    static func canRun(hadWindow: Bool, window: NSWindow?) -> Bool {
        guard hadWindow else { return true }
        guard let window else { return false }
        return window.isVisible || window.isMiniaturized || NSApp?.isHidden == true
    }

    // MARK: Getting photos ready

    /// Photos decoded so far (loaded or failed).
    var doneCount: Int { pages.indices.filter { store.isDone($0) }.count }
    /// Photos that will print as an empty frame.
    var notLoadedCount: Int { pages.indices.filter { store.image(at: $0) == nil }.count }

    /// Waits on the main actor without blocking it until every photo is
    /// decoded or `PrintWait.timeout` passes. After 300 ms a sheet shows
    /// the progress with Cancel. False: the user cancelled (no print job).
    func prepare(on window: NSWindow?) async -> Bool {
        let start = ContinuousClock.now
        var clock = PrintWait.Clock(start: start)
        var sheet: PrintPrepSheet?
        defer { sheet?.close() }
        while true {
            let now = ContinuousClock.now
            let elapsed = now - start
            let sinceProgress = clock.sinceProgress(done: doneCount, now: now)
            switch PrintWait.decide(elapsed: elapsed, sinceProgress: sinceProgress, done: doneCount, total: pages.count,
                                    sheetShown: sheet != nil, cancelled: sheet?.cancelled ?? false) {
            case .ready, .timedOut: return true
            case .cancel:
                for task in decodes { task.cancel() }
                return false
            case .showSheet:
                // On the window; app-modal when none. Both print entry
                // points always have a window (viewer, browser), so with none
                // Shrike just waits without a sheet.
                if let window { sheet = PrintPrepSheet(on: window, total: pages.count) }
            case .wait: break
            }
            sheet?.update(done: doneCount)
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    /// One line after printing starts when some photos did not load.
    func tellNotLoaded(on window: NSWindow?) {
        guard let text = PrintWait.notLoadedLine(notLoadedCount), let window,
              let host = RenameRecoveryPresenter.toastHost(in: window) else { return }
        host.show(ToastContent(text, kind: .error))
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
        #if DEBUG
        let debugDelay = DebugReviewOptions.current.printLoadDelay
        #endif
        for lane in 0..<min(lanes, items.count) {
            let mine = items.filter { $0.offset % lanes == lane }
            decodes.append(Task.detached(priority: .userInitiated) { [weak self] in
                for (index, page) in mine {
                    #if DEBUG
                    if debugDelay > 0 { try? await Task.sleep(for: .seconds(debugDelay)) }
                    #endif
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            // The line shows only once printing really started (not on Cancel).
            if success { self.tellNotLoaded(on: self.hostWindow) }
            self.finish()
        }
    }

    func finish() {
        for task in decodes { task.cancel() }
        Self.running.removeAll { $0 === self }
    }
}

// MARK: - Getting photos ready

/// The wait before the print panel. Pure.
enum PrintWait {
    /// Under this nothing is shown.
    static let sheetDelay: Duration = .milliseconds(300)
    /// The limit is per photo: when no photo has finished loading for this
    /// long, the ones still missing print as an empty frame with their name.
    /// The clock restarts each time a photo finishes (loaded or failed).
    static let timeout: Duration = .seconds(60)

    /// Time since the last photo finished (or since the start). Pure.
    struct Clock {
        private var progressAt: ContinuousClock.Instant
        private var lastDone = 0
        init(start: ContinuousClock.Instant) { progressAt = start }
        mutating func sinceProgress(done: Int, now: ContinuousClock.Instant) -> Duration {
            if done != lastDone { lastDone = done; progressAt = now }
            return now - progressAt
        }
    }

    enum Step: Equatable { case wait, showSheet, ready, timedOut, cancel }

    /// `elapsed`: since the wait began (the 300 ms sheet delay). `sinceProgress`:
    /// since the last photo finished (the 60 s limit).
    static func decide(elapsed: Duration, sinceProgress: Duration, done: Int, total: Int,
                       sheetShown: Bool, cancelled: Bool) -> Step {
        if cancelled { return .cancel }
        if done >= total { return .ready }
        if sinceProgress >= timeout { return .timedOut }
        if !sheetShown, elapsed >= sheetDelay { return .showSheet }
        return .wait
    }

    static let title = "Getting photos ready"
    /// "3 of 12 photos".
    static func progress(done: Int, total: Int) -> String {
        "\(min(done, total)) of \(total) \(total == 1 ? "photo" : "photos")"
    }
    static func notLoadedLine(_ n: Int) -> String? {
        guard n > 0 else { return nil }
        return n == 1 ? "1 photo couldn't be loaded." : "\(n) photos couldn't be loaded."
    }
}

/// The "Getting photos ready" sheet: a determinate bar, "3 of 12 photos", Cancel.
@MainActor
final class PrintPrepSheet {
    private let alert: NSAlert
    private let bar = NSProgressIndicator(frame: NSRect(x: 0, y: 22, width: 260, height: 16))
    private let line = NSTextField(labelWithString: "")
    private let total: Int
    private weak var parent: NSWindow?
    private(set) var cancelled = false

    init(on window: NSWindow, total: Int) {
        self.total = total
        parent = window
        alert = ShrikeAlert.make(message: PrintWait.title, style: .informational, buttons: [.cancel()])
        // Nothing is written while photos load: the sheet must not hold ⌘Q back.
        alert.window.preventsApplicationTerminationWhenModal = false
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(max(1, total))
        line.frame = NSRect(x: 0, y: 0, width: 260, height: 16)
        line.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        line.textColor = .secondaryLabelColor
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 40))
        box.addSubview(bar)
        box.addSubview(line)
        alert.accessoryView = box
        update(done: 0)
        // The alert's own informative text is empty here: VoiceOver must not stop on it.
        alert.layout()
        if let content = alert.window.contentView { Self.hideEmptyTexts(in: content, keeping: line) }
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if response != .stop { self?.cancelled = true }
            }
        }
    }

    /// Hides empty, non-editable text fields under `view` (out of the accessibility tree).
    static func hideEmptyTexts(in view: NSView, keeping kept: NSView) {
        for sub in view.subviews {
            if sub !== kept, let field = sub as? NSTextField, !field.isEditable, field.stringValue.isEmpty {
                field.isHidden = true   // an empty field draws nothing; hidden, VoiceOver skips it
            }
            hideEmptyTexts(in: sub, keeping: kept)
        }
    }

    func update(done: Int) {
        bar.doubleValue = Double(min(done, total))
        line.stringValue = PrintWait.progress(done: done, total: total)
    }

    func close() {
        guard alert.window.isVisible, let parent else { return }
        parent.endSheet(alert.window, returnCode: .stop)
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
