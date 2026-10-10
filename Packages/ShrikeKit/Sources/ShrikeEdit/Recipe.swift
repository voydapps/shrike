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
    /// Snapped rotation in quarter-turns. `+1` = CW 90°, `+2` = 180°,
    /// `-1` = CCW 90°. Value is normalised mod 4 at apply time.
    case rotate90(quarters: Int)
    case resize(ResizeSpec)
    case colorAdjust(ColorAdjustParams)
    /// Levels. Whole-state, last one wins. Always replayed
    /// after the effective `.colorAdjust`, wherever it sits in the list.
    case levels(LevelsParams)

    /// True for the ops that change the image's shape or size: `crop`,
    /// `rotate`, `rotate90`, `resize`. These replay in list order.
    public var isGeometry: Bool {
        switch self {
        case .crop, .rotate, .rotate90, .resize: return true
        case .colorAdjust, .levels: return false
        }
    }
}

// MARK: - EditRecipe

/// Ordered list of `EditOperation` values plus an undo/redo pair of stacks.
///
/// The list is the undo history, not the render list. Colour and levels
/// ops are whole-state: the last `.colorAdjust` and the last `.levels`
/// win, and earlier ones of the same kind only matter again after an
/// undo. Renderers replay `effectiveOperations(_:)`; panels read their
/// values back with `effectiveColorAdjust(_:)` / `effectiveLevels(_:)`.
///
/// Thread model: mutation is serialised through the actor; the UI
/// (`@MainActor`) and `EditRenderer` (background actor) both access the
/// recipe through `await` hops.
public actor EditRecipe {

    public private(set) var operations: [EditOperation] = []
    /// Redo stack. `undo()` pops from `operations` and pushes here;
    /// `redo()` pops from here and pushes back onto `operations`; any
    /// `append` or `replaceLast` clears this stack (standard redo
    /// semantics).
    public private(set) var undoneOperations: [EditOperation] = []

    public init(operations: [EditOperation] = []) {
        self.operations = operations
    }

    // MARK: Mutation

    /// Append a new op. Clears the redo stack — once the user forks the
    /// timeline, the old future is unreachable.
    public func append(_ op: EditOperation) {
        operations.append(op)
        undoneOperations.removeAll(keepingCapacity: true)
    }

    /// Replace the tail of the operations list with `op`, preserving undo
    /// depth. Used for slider-drag coalescing: while a continuous
    /// drag is in progress, successive `.colorAdjust` frames overwrite
    /// the last op rather than piling new ones up.
    ///
    /// If the list is empty this is equivalent to `append`.
    public func replaceLast(_ op: EditOperation) {
        if operations.isEmpty {
            operations.append(op)
        } else {
            operations[operations.count - 1] = op
        }
        undoneOperations.removeAll(keepingCapacity: true)
    }

    /// Pop the last op onto the redo stack. Returns the popped op so
    /// callers can emit a targeted signal (toast / UI focus). Returns
    /// `nil` when the stack is empty.
    @discardableResult
    public func undo() -> EditOperation? {
        guard let last = operations.popLast() else { return nil }
        undoneOperations.append(last)
        return last
    }

    /// Pop the last op off the redo stack back onto the operations list.
    /// Returns the re-applied op, or `nil` when the redo stack is empty.
    @discardableResult
    public func redo() -> EditOperation? {
        guard let last = undoneOperations.popLast() else { return nil }
        operations.append(last)
        return last
    }

    /// Wipe both stacks. Called on save and on explicit
    /// "Reset" of the whole recipe.
    public func reset() {
        operations.removeAll(keepingCapacity: true)
        undoneOperations.removeAll(keepingCapacity: true)
    }

    // MARK: Read

    public var isEmpty: Bool { operations.isEmpty }

    /// True when the recipe has any pending state — either applied ops
    /// waiting to be saved OR an undo history that a save would clear.
    ///
    /// The exit-modal flow consumes this property to decide
    /// whether to prompt "Discard / Cancel / Save As / Save".
    public var isDirty: Bool {
        !operations.isEmpty || !undoneOperations.isEmpty
    }

    /// Snapshot of the current ops list. Cheap copy (value type).
    public func snapshot() -> [EditOperation] {
        operations
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
            case .crop, .rotate, .rotate90, .resize:
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
