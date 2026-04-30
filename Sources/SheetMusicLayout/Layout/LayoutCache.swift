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

    /// Hit/miss counters, useful for tests to assert that the cache
    /// is actually taking effect. Counts one event per per-measure
    /// width lookup and per per-(measure, staff) placement lookup.
    /// Reset to zero at the start of every `LayoutEngine.layout(...)`
    /// call.
    var widthHits: Int = 0
    var widthMisses: Int = 0
    var placementHits: Int = 0
    var placementMisses: Int = 0

    /// One measure's cached inputs and outputs. The width portion is
    /// consumed by `packSystems`; the per-staff `placements`
    /// portion by `buildSystem`.
    struct Entry {
        // --- Inputs that determine `crossStaffMinimumMeasureWidth` ---
        let measures: [Measure?]      // one per staff (nil if absent)
        let sp: CGFloat
        let division: Int

        // --- Output of crossStaffMinimumMeasureWidth ---
        let minWidth: CGFloat

        // --- Per-staff placement results ---
        var placements: [Int: StaffPlacement]
    }

    struct StaffPlacement {
        let inputs: PlacementInputs
        let elements: [LayoutElement]
        let newClef: NotatedClef
        let newKey: Int
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
        let incomingMelismas: [MelismaContinuation]
        let effectiveMelismaTicks: [MelismaLyricKey: Int]
    }
}
