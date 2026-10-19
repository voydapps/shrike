//
//  Recipe.swift
//  ShrikeEdit
//
//  Non-destructive edit recipe: ordered list of `EditOperation` values plus
//  an undo/redo pair of stacks, wrapped in an `actor`. The UI drives the
//  recipe from `@MainActor`; `EditRenderer` replays it on a background
//  actor.
//  Why an actor: multiple renders and UI reads can race if the recipe is
//  mutated from the main thread while a background render is iterating
//  `operations`. Serialising through an actor gives us a single writer /
//  single consistent snapshot per suspension point without hand-rolled
//  locks. The ops list is cheap (at most tens of entries) so copying on
//  read for `replay` is fine.
//

import Foundation

// MARK: - Supporting scalars

/// Interpolation strategy for `EditOperation.resize`.
///
/// Lanczos is the default. The enum is exhaustive on purpose so new
/// values force the `ResizeTool` switch to be updated.
public enum Interpolation: String, Sendable, Codable {
    case lanczos
    case bicubic
    case bilinear
    case nearest
}

/// Normalised crop rectangle in the coordinate space of the *intermediate*
/// image the crop is applied to. All values in `0…1`, origin top-left.
///
/// Coordinates are normalised rather than pixel-absolute so the same crop
/// rect applied after a resize lands in the right place — the recipe is
/// order-dependent.
public struct CropRect: Sendable, Codable, Equatable, Hashable {
    public var originX: Double
    public var originY: Double
    public var width: Double
    public var height: Double

    public init(originX: Double, originY: Double, width: Double, height: Double) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }

    /// Full-image crop — an identity op. Useful as a baseline.
    public static let full = CropRect(originX: 0, originY: 0, width: 1, height: 1)

    /// True when all dimensions are finite and the rect is non-empty and
    /// fully contained in `[0,1]²`. Render paths treat invalid rects as
    /// identity.
    public var isValid: Bool {
        guard originX.isFinite, originY.isFinite, width.isFinite, height.isFinite else {
            return false
        }
        guard width > 0, height > 0 else { return false }
        guard originX >= 0, originY >= 0 else { return false }
        guard originX + width <= 1 + 1e-9 else { return false }
        guard originY + height <= 1 + 1e-9 else { return false }
        return true
    }
}

/// Target size + strategy for `EditOperation.resize`.
public struct ResizeSpec: Sendable, Codable, Equatable, Hashable {
    public var width: Int
    public var height: Int
    public var interpolation: Interpolation
    /// When true, a resize that would enlarge the image is clamped to the
    /// source dimensions and becomes a no-op.
    public var preventUpscale: Bool

    public init(width: Int, height: Int, interpolation: Interpolation, preventUpscale: Bool) {
        self.width = width
        self.height = height
        self.interpolation = interpolation
        self.preventUpscale = preventUpscale
    }
}

/// Parameters for `EditOperation.colorAdjust`.
///
/// Brightness / contrast / saturation are used today. Eight additional slots are
/// reserved as `Double?` so they can be filled in later without a recipe-data
/// migration. `nil` means "not applied" — the renderer
/// treats nil fields as identity.
public struct ColorAdjustParams: Sendable, Codable, Equatable, Hashable {
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double

    /// Hue shift in degrees, -180…+180. nil or 0 = none.
    public var hue: Double?
    // Reserved for later. All nil = not applied.
    public var exposure: Double?
    public var temperature: Double?
    public var tint: Double?
    public var shadows: Double?
    public var highlights: Double?
    public var whites: Double?
    public var blacks: Double?

    public init(
        brightness: Double = 0,
        contrast: Double = 0,
        saturation: Double = 0,
        exposure: Double? = nil,
        hue: Double? = nil,
        temperature: Double? = nil,
        tint: Double? = nil,
        shadows: Double? = nil,
        highlights: Double? = nil,
        whites: Double? = nil,
        blacks: Double? = nil
    ) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.exposure = exposure
        self.hue = hue
        self.temperature = temperature
        self.tint = tint
        self.shadows = shadows
        self.highlights = highlights
        self.whites = whites
        self.blacks = blacks
    }

    /// Identity — produces no visual change.
    public static let identity = ColorAdjustParams()

    /// True when every slider is at the identity value. Renderer short-
    /// circuits a no-op pass when this is true.
    public var isIdentity: Bool {
        brightness == 0 &&
        contrast == 0 &&
        saturation == 0 &&
        exposure == nil &&
        (hue ?? 0) == 0 &&
        temperature == nil &&
        tint == nil &&
        shadows == nil &&
        highlights == nil &&
        whites == nil &&
        blacks == nil
    }
}

// MARK: - EditOperation

/// One step inside an `EditRecipe`.
///
/// Two kinds of op:
///
/// - **Geometry** (`crop`, `rotate`, `rotate90`, `resize`) is a step. The
///   replay is **order-dependent** — a recipe `[rotate90(1), crop(…)]`
///   crops a rotated image; `[crop(…), rotate90(1)]` crops first, then
///   rotates. This is observable to the user and tested
/// - **Whole-state** (`colorAdjust`, `levels`) holds the full panel state
///   (every slider value), not a delta. Only the **last** op of each kind
///   counts: a newer `.colorAdjust` replaces an older one, it does not add
///   to it. Undo pops the newest, so the one before it is effective
///   again.
///
/// Every render path replays `EditRecipe.effectiveOperations(_:)`, never
/// the raw list.
public enum EditOperation: Sendable, Codable, Equatable, Hashable {
    case crop(CropRect)
    /// Free rotate, degrees in `-45…+45`
    case rotate(degrees: Double)
    /// Free rotate with blank corners removed. The legacy degrees-only case
    /// retains its expanded-canvas meaning when decoding existing recipes.
    case rotateAutoCrop(degrees: Double)
    /// Snapped rotation in quarter-turns. `+1` = CW 90°, `+2` = 180°,
    /// `-1` = CCW 90°. Value is normalised mod 4 at apply time.
    case rotate90(quarters: Int)
    case resize(ResizeSpec)
    case colorAdjust(ColorAdjustParams)
    /// Levels. Whole-state, last one wins. Always replayed
    /// after the effective `.colorAdjust`, wherever it sits in the list.
    case levels(LevelsParams)

    /// The immutable free-rotation parameters, shared by panel readback and replay.
    public var freeRotation: (degrees: Double, autoCrop: Bool)? {
        switch self {
        case .rotate(let degrees): return (degrees, false)
        case .rotateAutoCrop(let degrees): return (degrees, true)
        default: return nil
        }
    }

    /// True for the ops that change the image's shape or size: `crop`,
    /// `rotate`, `rotate90`, `resize`. These replay in list order.
    public var isGeometry: Bool {
        switch self {
        case .crop, .rotate, .rotateAutoCrop, .rotate90, .resize: return true
        case .colorAdjust, .levels: return false
        }
    }
}

// MARK: - EditRecipe

/// Ordered list of `EditOperation` values plus an undo/redo pair of stacks.
///
/// Operations are the ordered replay list. Undo history additionally records
/// owned parameter revisions without accumulating their geometry. Colour and levels
/// ops are whole-state: the last `.colorAdjust` and the last `.levels`
/// win, and earlier ones of the same kind only matter again after an
/// undo. Renderers replay `effectiveOperations(_:)`; panels read their
/// values back with `effectiveColorAdjust(_:)` / `effectiveLevels(_:)`.
///
/// Thread model: mutation is serialised through the actor; the UI
/// (`@MainActor`) and `EditRenderer` (background actor) both access the
/// recipe through `await` hops.
public actor EditRecipe {

    /// An in-memory point in the recipe's complete undo/redo timeline.
    /// Tool transitions use it to discard only the current tool's changes
    /// while retaining edits and redo steps accepted before that tool opened.
    /// It contains parameter values and ephemeral owners only; no source images.
    public struct Checkpoint: Sendable, Equatable {
        fileprivate let operations: [EditOperation]
        fileprivate let owners: [GeometryOwner?]
        fileprivate let editableOwner: GeometryOwner?
        fileprivate let knownOwners: Set<GeometryOwner>
        fileprivate let undoHistory: [HistoryEntry]
        fileprivate let redoHistory: [HistoryEntry]
    }

    /// Ephemeral ownership of one editable free-rotation segment. It is not
    /// serialized into the recipe and never retains images or UI objects.
    public struct GeometryOwner: Sendable, Hashable {
        private let id = UUID()
        public init() {}
    }

    fileprivate struct TailState: Sendable, Equatable {
        var operations: [EditOperation]
        var owners: [GeometryOwner?]
        var editableOwner: GeometryOwner?
    }
    /// Only the changed tail is retained. Ordinary appends/revisions cost a
    /// constant number of parameter values, rather than copying every prefix.
    fileprivate struct HistoryEntry: Sendable, Equatable {
        var prefixCount: Int
        var before: TailState
        var after: TailState
        var operation: EditOperation? { after.operations.last ?? before.operations.last }
    }

    public private(set) var operations: [EditOperation] = []
    private var owners: [GeometryOwner?] = []
    private var editableOwner: GeometryOwner?
    private var knownOwners: Set<GeometryOwner> = []
    private var undoHistory: [HistoryEntry] = []
    private var redoHistory: [HistoryEntry] = []
    /// Legacy operation view of the redo stack. History depths also count
    /// replacements/removals whose replay list does not grow.
    public var undoneOperations: [EditOperation] { redoHistory.compactMap(\.operation) }
    public var undoDepth: Int { undoHistory.count }
    public var redoDepth: Int { redoHistory.count }

    public init(operations: [EditOperation] = []) {
        self.operations = operations
        owners = Array(repeating: nil, count: operations.count)
        undoHistory = operations.enumerated().map { index, operation in
            HistoryEntry(prefixCount: index,
                         before: TailState(operations: [], owners: [], editableOwner: nil),
                         after: TailState(operations: [operation], owners: [nil], editableOwner: nil))
        }
    }

    // MARK: Mutation

    public func append(_ op: EditOperation) {
        let prefix = operations.count
        let before = tail(from: prefix)
        _ = change(prefix: prefix, before: before,
                   after: TailState(operations: [op], owners: [nil], editableOwner: nil), recordUndo: true)
    }

    /// A continuous frame replaces its current history transaction, preserving
    /// the existing no-new-gesture semantics for Color Adjust and Levels.
    public func replaceLast(_ op: EditOperation) {
        guard !operations.isEmpty else { append(op); return }
        let prefix = operations.count - 1
        _ = change(prefix: prefix, before: tail(from: prefix),
                   after: TailState(operations: [op], owners: [nil], editableOwner: nil), recordUndo: false)
        redoHistory.removeAll(keepingCapacity: true)
    }

    /// Atomically refine one owned absolute free rotation. A new gesture keeps
    /// the previous parameters for Undo without replaying both geometries.
    /// Nil removes only this segment's tail, retaining identity ownership.
    @discardableResult
    public func setOwnedFreeRotation(_ op: EditOperation?, owner: GeometryOwner,
                                     beginsUndoStep: Bool) -> Bool {
        guard op == nil || op?.freeRotation != nil else { return false }
        let ownsTail = (owners.last ?? nil) == owner
        // Current state atomically proves the unchanged segment prefix/tail.
        // A previously used owner cannot append after an unrelated boundary.
        if knownOwners.contains(owner), editableOwner != owner { return false }
        if owners.contains(owner), !ownsTail { return false }
        guard ownsTail || op != nil else { return false }
        let prefix = ownsTail ? operations.count - 1 : operations.count
        let after = TailState(operations: op.map { [$0] } ?? [],
                              owners: op.map { _ in [Optional(owner)] } ?? [], editableOwner: owner)
        let changed = change(prefix: prefix, before: tail(from: prefix), after: after,
                             recordUndo: beginsUndoStep || undoHistory.last?.after.editableOwner != owner)
        if changed { knownOwners.insert(owner) }
        return changed
    }

    /// Includes a meaningful identity segment after its angle returned to0.
    public func ownedFreeRotation() -> (owner: GeometryOwner, operation: EditOperation?)? {
        guard let editableOwner else { return nil }
        return (editableOwner, (owners.last ?? nil) == editableOwner ? operations.last : nil)
    }

    private func tail(from prefix: Int) -> TailState {
        TailState(operations: Array(operations.dropFirst(prefix)), owners: Array(owners.dropFirst(prefix)),
                  editableOwner: editableOwner)
    }

    private func apply(_ tail: TailState, from prefix: Int) {
        operations.replaceSubrange(prefix..., with: tail.operations)
        owners.replaceSubrange(prefix..., with: tail.owners)
        editableOwner = tail.editableOwner
    }

    @discardableResult
    private func change(prefix: Int, before: TailState, after: TailState, recordUndo: Bool) -> Bool {
        guard before != after else { return false }
        if recordUndo || undoHistory.isEmpty {
            undoHistory.append(HistoryEntry(prefixCount: prefix, before: before, after: after))
        } else {
            // Widen only when a legacy replaceLast edits a prefix preceding
            // the newest transaction (for example after a tail removal).
            var last = undoHistory.removeLast()
            let mergedPrefix = min(prefix, last.prefixCount)
            let unchangedOps = Array(operations[mergedPrefix..<last.prefixCount])
            let unchangedOwners = Array(owners[mergedPrefix..<last.prefixCount])
            last.before.operations = unchangedOps + last.before.operations
            last.before.owners = unchangedOwners + last.before.owners
            last.prefixCount = mergedPrefix
            apply(after, from: prefix)
            last.after = tail(from: mergedPrefix)
            if last.before.operations != last.after.operations || last.before.owners != last.after.owners {
                undoHistory.append(last)
            }
            redoHistory.removeAll(keepingCapacity: true)
            return true
        }
        apply(after, from: prefix)
        redoHistory.removeAll(keepingCapacity: true)
        return true
    }

    @discardableResult
    public func undo() -> EditOperation? {
        guard let entry = undoHistory.popLast() else { return nil }
        apply(entry.before, from: entry.prefixCount)
        redoHistory.append(entry)
        return entry.operation
    }

    @discardableResult
    public func redo() -> EditOperation? {
        guard let entry = redoHistory.popLast() else { return nil }
        apply(entry.after, from: entry.prefixCount)
        undoHistory.append(entry)
        return entry.operation
    }

    public func reset() {
        operations.removeAll(keepingCapacity: true)
        owners.removeAll(keepingCapacity: true)
        editableOwner = nil
        knownOwners.removeAll(keepingCapacity: true)
        undoHistory.removeAll(keepingCapacity: true)
        redoHistory.removeAll(keepingCapacity: true)
    }

    public func restore(_ checkpoint: Checkpoint) {
        operations = checkpoint.operations
        owners = checkpoint.owners
        editableOwner = checkpoint.editableOwner
        knownOwners = checkpoint.knownOwners
        undoHistory = checkpoint.undoHistory
        redoHistory = checkpoint.redoHistory
    }

    // MARK: Read

    public var isEmpty: Bool { operations.isEmpty }

    /// True when the recipe has any pending state — either applied ops
    /// waiting to be saved OR an undo history that a save would clear.
    ///
    /// The exit-modal flow consumes this property to decide
    /// whether to prompt "Discard / Cancel / Save As / Save".
    public var isDirty: Bool {
        !operations.isEmpty || !undoHistory.isEmpty || !redoHistory.isEmpty
    }

    /// Snapshot of the current ops list. Cheap copy (value type).
    public func snapshot() -> [EditOperation] {
        operations
    }

    /// Capture the applied steps and the exact order of the redo stack.
    public func checkpoint() -> Checkpoint {
        Checkpoint(operations: operations, owners: owners, editableOwner: editableOwner, knownOwners: knownOwners,
                   undoHistory: undoHistory, redoHistory: redoHistory)
    }

    /// Whether the effective replay has changed since the checkpoint.
    /// Redo-only differences and superseded whole-state steps do not change
    /// the image. Known renderer identity geometry is ignored here only;
    /// the stored history and global effective replay remain unchanged.
    /// This compares replay values, without rendering pixels.
    public func hasContentChanges(since checkpoint: Checkpoint) -> Bool {
        Self.contentOperations(operations) != Self.contentOperations(checkpoint.operations)
    }

    private static func contentOperations(_ operations: [EditOperation]) -> [EditOperation] {
        effectiveOperations(operations).filter { operation in
            switch operation {
            case .rotate(let degrees), .rotateAutoCrop(let degrees): return !RotateTool.isIdentity(degrees: degrees)
            case .rotate90(let quarters): return quarters % 4 != 0
            case .crop(let crop): return !CropTool.isIdentity(crop)
            case .resize, .colorAdjust, .levels: return true
            }
        }
    }
}

// MARK: - Effective replay (whole-state ops: last one wins)

extension EditRecipe {

    /// The list every render path replays, built from the undo history
    /// `ops`:
    ///
    /// 1. every geometry op (`crop`, `rotate`, `rotate90`, `resize`), in
    ///    list order;
    /// 2. then the **last** `.colorAdjust`, unless it is identity;
    /// 3. then the **last** `.levels`, unless it is identity.
    ///
    /// Earlier colour / levels ops are dropped: each one holds the whole
    /// panel state, so replaying two would apply brightness twice. Levels
    /// always runs after Color Adjust. Both are per-pixel,
    /// so running them after the geometry matches running them before
    /// (and costs less after a crop or a shrink).
    ///
    /// Pure and cheap (one pass over at most tens of ops).
    public static func effectiveOperations(_ ops: [EditOperation]) -> [EditOperation] {
        var out: [EditOperation] = []
        out.reserveCapacity(ops.count)
        var color: ColorAdjustParams?
        var levels: LevelsParams?
        for op in ops {
            switch op {
            case .crop, .rotate, .rotateAutoCrop, .rotate90, .resize:
                out.append(op)
            case .colorAdjust(let p):
                color = p
            case .levels(let p):
                levels = p
            }
        }
        if let color, !color.isIdentity { out.append(.colorAdjust(color)) }
        if let levels, !levels.isIdentity { out.append(.levels(levels)) }
        return out
    }

    /// The Color Adjust values in effect for `ops`: the last
    /// `.colorAdjust`, or `.identity` when there is none. The colour
    /// panel re-reads its sliders from this after undo / redo / a tool
    /// switch.
    public static func effectiveColorAdjust(_ ops: [EditOperation]) -> ColorAdjustParams {
        for op in ops.reversed() {
            if case .colorAdjust(let p) = op { return p }
        }
        return .identity
    }

    /// The Levels values in effect for `ops`: the last `.levels`, or
    /// `.identity` when there is none. The Levels panel re-reads its
    /// handles from this after undo / redo / a tool switch.
    public static func effectiveLevels(_ ops: [EditOperation]) -> LevelsParams {
        for op in ops.reversed() {
            if case .levels(let p) = op { return p }
        }
        return .identity
    }

    /// The list that produces the image as it enters Levels: the
    /// effective replay without the levels op. Its render feeds the
    /// histogram for Auto Contrast / Auto Color.
    public static func levelsInputOperations(_ ops: [EditOperation]) -> [EditOperation] {
        effectiveOperations(ops).filter {
            if case .levels = $0 { return false }
            return true
        }
    }
}
