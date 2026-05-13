import CoreGraphics
import SheetMusicCore

/// Per-measure cache for incremental layout. Threaded through
/// `LayoutEngine.layout(score:options:availableWidth:cache:)` so a
/// subsequent call can skip per-measure work for measures whose
/// inputs haven't changed since the prior call.
///
/// ## Lifecycle
///
/// The cache is reused across layout calls — pass the same instance
/// each time. Each call REBUILDS the cache in place: entries from
/// the prior call are copied forward only when the corresponding
/// measure's inputs still match. Stale entries are dropped.
///
/// ## Thread safety
///
/// `LayoutEngine.layout` is synchronous and assumed to run on a
/// single thread per call. The cache must not be shared across
/// concurrent layout calls.
@available(macOS 15.0, iOS 16.0, *)
public final class LayoutCache: @unchecked Sendable {
    public init() {}

    /// Per-measure cache entries. The key is `measureIdx`.
    var entries: [Int: Entry] = [:]

    /// Per-system cache entries. The key is the system's starting
    /// `measureIdx`. A hit lets `packSystems` skip the entire
    /// `buildSystem` call for that system (and with it the
    /// per-system Y align, skyline, translate, eventColumns work).
    var systemEntries: [Int: SystemEntry] = [:]

    /// Hit/miss counters, useful for tests to assert that the cache
    /// is actually taking effect. Counts one event per per-measure
    /// width lookup and per per-(measure, staff) placement lookup.
    /// Reset to zero at the start of every `LayoutEngine.layout(...)`
    /// call.
    var widthHits = 0
    var widthMisses = 0
    var placementHits = 0
    var placementMisses = 0
    var systemHits = 0
    var systemMisses = 0

    /// One measure's cached inputs and outputs. The width portion is
    /// consumed by `packSystems`; the per-staff `placements`
    /// portion by `buildSystem`.
    struct Entry {
        // --- Inputs that determine `crossStaffMinimumMeasureWidth` ---
        let measures: [Measure?] // one per staff (nil if absent)
        let sp: CGFloat
        let division: Int

        /// --- Output of crossStaffMinimumMeasureWidth ---
        let minWidth: CGFloat

        /// --- Per-staff placement results ---
        var placements: [Int: StaffPlacement]
    }

    struct StaffPlacement {
        let inputs: PlacementInputs
        let elements: [LayoutElement]
        let newClef: NotatedClef
        let newKey: Int
    }

    /// One system's cached inputs and outputs. The cached `system`
    /// is normalised to `origin.y == 0`; callers shift it to the
    /// current packing Y when they consume the entry.
    struct SystemEntry {
        let inputs: SystemInputs
        let system: LayoutSystem
        let activeClefsOut: [NotatedClef]
        let activeKeysOut: [Int]
    }

    /// All inputs to `buildSystem` for one system. Equality is the
    /// cache-hit predicate.
    ///
    /// `systemOriginY` is intentionally NOT included — the cached
    /// system is stored at `origin.y == 0` and shifted on retrieval.
    /// Two layout calls that wrap the same way but at different Y
    /// (e.g. when a title frame appears or a prior system's height
    /// changed) hit the cache for downstream systems.
    struct SystemInputs: Equatable {
        let measureStart: Int
        let measureCount: Int
        let widths: [CGFloat]
        let isFirstSystem: Bool
        let activeClefsIn: [NotatedClef]
        let activeKeysIn: [Int]
        let sp: CGFloat
        let availableWidth: CGFloat
        let division: Int
        /// Per-staff measures for the range. `[staffIdx][localIdx]`,
        /// where `localIdx = absolute measureIdx - measureStart`.
        let measuresPerStaff: [[Measure?]]
        /// The score-wide melisma data — `placeMeasureElements` reads
        /// it via `effectiveMelismaTicks` keys that touch this range.
        let effectiveMelismaTicks: [MelismaLyricKey: Int]
        /// Sliced to this range: `[staffIdx][localMeasureIdx]`.
        let melismaContinuationsForRange: [[[MelismaContinuation]]]
        /// Drum maps per staff. Static for the score; included so a
        /// part-instrument change invalidates affected systems.
        let drumLineMaps: [[Int: Int]?]
        let totalMeasures: Int
        let options: ScoreViewOptions
    }

    /// All inputs to `placeMeasureElements` for one (measure, staff).
    /// Equality is the cache-hit predicate — when the current call's
    /// inputs match the snapshot, the prior call's outputs can be
    /// reused.
    struct PlacementInputs: Equatable {
        let measure: Measure
        let width: CGFloat
        let metricsSp: CGFloat
        let activeClef: NotatedClef
        let activeKey: Int
        let initialClefRawType: String?
        let initialKeyForSynth: Int?
        let headerSchedule: LayoutEngine.HeaderSchedule
        let tickColumns: [Int: CGFloat]
        let division: Int
        let drumLineMap: [Int: Int]?
        let isLastMeasure: Bool
        let isFirstSystem: Bool
        let incomingMelismas: [MelismaContinuation]
        let effectiveMelismaTicks: [MelismaLyricKey: Int]
        let graceNoteMag: CGFloat
        /// Whether a visible below-staff spanner (hairpin/pedal) covers
        /// this measure for this staff. Affects lyric Y placement.
        let coversBelowStaffSpanner: Bool
        /// System-level elements (tempo / rehearsal / system or staff
        /// text / swing) routed to this staff for this measure. The
        /// caller pre-filters `Score.systemMeasures` by staff address;
        /// changes here invalidate the placement cache so reflows
        /// pick up edited or relocated system markings.
        let systemElements: [PositionedSystemElement]
    }
}
