//
//  PrintSettings.swift
//  ShrikeCore
//
//  Print and contact-sheet settings. The model
//  is a plain Codable value; `PrintSettingsStore` keeps it in
//  `UserDefaults`, one value per `shrike.print.*` key, so each key has the
//  type the settings table gives it and `Prefs.resetAll()` wipes it.
//
//  The UI (the Print panel accessory and the Contact Sheet sheet) comes
//  later; ShrikeEdit bridges the contact-sheet part to `ContactSheetOptions`.
//

import Foundation

/// What the Print panel and the Contact Sheet sheet remember.
public struct PrintSettings: Codable, Sendable, Hashable {

    /// Print ▸ Scaling.
    public enum Scaling: String, Codable, Sendable, CaseIterable {
        /// Largest size inside the margins.
        case fit
        /// Covers the printable area; centred crop.
        case fill
        /// From the file's DPI (300 ppi when missing); centred, cropped.
        case actual
    }

    /// Page orientation. `automatic` follows the image: a landscape image
    /// prints on a landscape page.
    public enum Orientation: String, Codable, Sendable, CaseIterable {
        case automatic = "auto"
        case portrait
        case landscape

        /// The page orientation for an image of `width` × `height` pixels
        /// (after EXIF orientation). Square images print portrait.
        public func resolved(imageWidth width: Int, imageHeight height: Int) -> Orientation {
            guard self == .automatic else { return self }
            return width > height ? .landscape : .portrait
        }
    }

    /// Contact sheet paper. Raw values match ShrikeEdit's `ContactSheetPaper`.
    public enum Paper: String, Codable, Sendable, CaseIterable {
        case a4
        case usLetter
    }

    /// Contact sheet caption. Raw values match ShrikeEdit's `ContactSheetCaption`.
    public enum Caption: String, Codable, Sendable, CaseIterable {
        case none
        case fileName
        case fileNameAndDate
    }

    /// Contact sheet columns: 3–8.
    public static let columnRange = 3...8
    public static let defaultColumns = 5

    public var scaling: Scaling
    /// Print the file name under the image.
    public var showFileName: Bool
    public var orientation: Orientation
    /// 3…8; values outside are clamped.
    public var contactSheetColumns: Int {
        get { _columns }
        set { _columns = Self.clampColumns(newValue) }
    }
    public var contactSheetPaper: Paper
    public var contactSheetCaption: Caption
    private var _columns: Int

    public init(
        scaling: Scaling = .fit,
        showFileName: Bool = false,
        orientation: Orientation = .automatic,
        contactSheetColumns: Int = PrintSettings.defaultColumns,
        contactSheetPaper: Paper = PrintSettings.defaultPaper(for: .current),
        contactSheetCaption: Caption = .fileName
    ) {
        self.scaling = scaling
        self.showFileName = showFileName
        self.orientation = orientation
        self._columns = Self.clampColumns(contactSheetColumns)
        self.contactSheetPaper = contactSheetPaper
        self.contactSheetCaption = contactSheetCaption
    }

    /// The defaults for a user in `locale` (paper from the region).
    public static func defaults(for locale: Locale) -> PrintSettings {
        PrintSettings(contactSheetPaper: defaultPaper(for: locale))
    }

    /// Countries that use US Letter (ICU's list); A4 everywhere else.
    private static let letterRegions: Set<String> = [
        "US", "CA", "MX", "CL", "CO", "CR", "DO", "GT", "PA", "PH", "PR", "SV", "VE", "BZ", "NI", "HN",
    ]

    /// US Letter for the Americas' letter countries, A4 otherwise.
    public static func defaultPaper(for locale: Locale) -> Paper {
        guard let region = locale.region?.identifier else { return .a4 }
        return letterRegions.contains(region) ? .usLetter : .a4
    }

    static func clampColumns(_ value: Int) -> Int {
        min(max(value, columnRange.lowerBound), columnRange.upperBound)
    }

    // Codable: the public names, and columns clamped on the way in.
    private enum CodingKeys: String, CodingKey {
        case scaling, showFileName, orientation, contactSheetColumns, contactSheetPaper, contactSheetCaption
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            scaling: try c.decode(Scaling.self, forKey: .scaling),
            showFileName: try c.decode(Bool.self, forKey: .showFileName),
            orientation: try c.decode(Orientation.self, forKey: .orientation),
            contactSheetColumns: try c.decode(Int.self, forKey: .contactSheetColumns),
            contactSheetPaper: try c.decode(Paper.self, forKey: .contactSheetPaper),
            contactSheetCaption: try c.decode(Caption.self, forKey: .contactSheetCaption)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scaling, forKey: .scaling)
        try c.encode(showFileName, forKey: .showFileName)
        try c.encode(orientation, forKey: .orientation)
        try c.encode(contactSheetColumns, forKey: .contactSheetColumns)
        try c.encode(contactSheetPaper, forKey: .contactSheetPaper)
        try c.encode(contactSheetCaption, forKey: .contactSheetCaption)
    }
}

/// Reads and writes `PrintSettings` in `UserDefaults`. Cheap value type;
/// every call reads the defaults (thread-safe), so any thread may use it.
public struct PrintSettingsStore: Sendable {

    /// One key per setting, typed says.
    public enum Key {
        /// String: `fit` | `fill` | `actual`. Default `fit`.
        public static let scaling = "shrike.print.scaling"
        /// Bool. Default false.
        public static let showFileName = "shrike.print.showFileName"
        /// String: `auto` | `portrait` | `landscape`. Default `auto`.
        public static let orientation = "shrike.print.orientation"
        /// Int 3–8. Default 5.
        public static let contactSheetColumns = "shrike.print.contactSheet.columns"
        /// String: `a4` | `usLetter`. Default from the locale's region.
        public static let contactSheetPaper = "shrike.print.contactSheet.paper"
        /// String: `none` | `fileName` | `fileNameAndDate`. Default `fileName`.
        public static let contactSheetCaption = "shrike.print.contactSheet.caption"

        public static let all = [
            scaling, showFileName, orientation, contactSheetColumns, contactSheetPaper, contactSheetCaption,
        ]
    }

    /// Settings in `ShrikeDefaults.store`, paper default from `.current`.
    public static let standard = PrintSettingsStore()

    // UserDefaults isn't Sendable in the SDK; Foundation locks internally.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let locale: Locale

    public init(defaults: UserDefaults = ShrikeDefaults.store, locale: Locale = .current) {
        self.defaults = defaults
        self.locale = locale
    }

    /// The stored settings. A missing key, or a value of the wrong type
    /// or out of the list (an old or hand-edited value), gives that
    /// setting's default. Columns out of range are clamped.
    public func load() -> PrintSettings {
        var settings = PrintSettings.defaults(for: locale)
        if let v = string(Key.scaling).flatMap(PrintSettings.Scaling.init(rawValue:)) { settings.scaling = v }
        if let v = defaults.object(forKey: Key.showFileName) as? Bool { settings.showFileName = v }
        if let v = string(Key.orientation).flatMap(PrintSettings.Orientation.init(rawValue:)) {
            settings.orientation = v
        }
        if let v = defaults.object(forKey: Key.contactSheetColumns) as? Int { settings.contactSheetColumns = v }
        if let v = string(Key.contactSheetPaper).flatMap(PrintSettings.Paper.init(rawValue:)) {
            settings.contactSheetPaper = v
        }
        if let v = string(Key.contactSheetCaption).flatMap(PrintSettings.Caption.init(rawValue:)) {
            settings.contactSheetCaption = v
        }
        return settings
    }

    /// Stores every setting.
    public func save(_ settings: PrintSettings) {
        defaults.set(settings.scaling.rawValue, forKey: Key.scaling)
        defaults.set(settings.showFileName, forKey: Key.showFileName)
        defaults.set(settings.orientation.rawValue, forKey: Key.orientation)
        defaults.set(settings.contactSheetColumns, forKey: Key.contactSheetColumns)
        defaults.set(settings.contactSheetPaper.rawValue, forKey: Key.contactSheetPaper)
        defaults.set(settings.contactSheetCaption.rawValue, forKey: Key.contactSheetCaption)
    }

    /// Changes some settings and stores them all; returns the result.
    @discardableResult
    public func update(_ change: (inout PrintSettings) -> Void) -> PrintSettings {
        var settings = load()
        change(&settings)
        save(settings)
        return settings
    }

    /// Removes every `shrike.print.*` key (back to the defaults).
    public func reset() {
        for key in Key.all { defaults.removeObject(forKey: key) }
    }

    private func string(_ key: String) -> String? {
        defaults.object(forKey: key) as? String
    }
}
