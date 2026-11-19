import SheetMusicFoundation

// Each staff remembers its effective measure durations until its measures change.
//
// `[Measure].effectiveMeasureDurations()` walks every bar of a staff — and, in a bar that declares no time signature,
// every element of every voice — so a per-element question that rebuilt it each time (`Score.onset(of:)`,
// `end(of:)`, `effectiveMeasureDuration(at:measureIndex:)`, `resolveTickInMeasure(for:)`) cost a whole-staff walk per
// call. A single selection question asked it two to six times: folino's Windows menu gate spent 5–17 ms per row on a
// one-bar selection and 20–70 ms on 127 bars (2026-11-19, the gate measurement that found it).
//
// **What the table depends on, and why `measures` alone keys it.** The walk reads only `measures` — each bar's
// `actualLength` and the first `.timeSignature` among its voices' elements. Nothing on the part or the score enters
// it: the time signature is carried forward within the staff's own bars, a pickup is that bar's `actualLength`, and a
// part's transposition or a staff's visibility play no part in a bar's length. So replacing the cache whenever
// `measures` is set — `Staff.measures`'s `didSet` — is the whole invalidation rule.
//
// **Why lazy, behind a box.** The `didSet` only swaps in an empty box (one allocation); the table is built the first
// time something asks, once. Building it in the `didSet` would put a whole-staff walk on every write, and an edit that
// writes element by element (transposing every note) would turn quadratic. A box rather than a stored array because a
// non-mutating read has to fill it. Copies of a staff share the box until one of them changes its measures, which is
// right: equal measures, equal table.
//
// **Concurrency.** A `Staff` is `Sendable` and read from several threads (layout, playback, the editor), so the box's
// one mutable slot is only touched under a lock. `SerialLock` is the portable one this package has (Dispatch, and a
// checked flag on single-threaded WASI); `Synchronization.Mutex` would need an iOS 18 / macOS 15 floor. One lock for
// every box: a fill holds it only to read or store the slot, never while walking the staff.

/// A staff's effective measure durations, built once on first use and dropped when the staff's measures change.
///
/// Not part of the staff's value: two staves are equal whatever their caches hold — `==` is always `true`, so
/// `Staff`'s synthesized `Equatable` reads the model alone. (`Staff` is not `Hashable`; were it made so, this must stay
/// out of the hash in the same way.)
final class StaffTimingCache: @unchecked Sendable {
    private static let lock = SerialLock(label: "io.github.jiyimeta.sheetmusic.staff-timing")

    /// Guarded by `lock`.
    private var durations: [Fraction]?

    init() {}

    /// `measures.effectiveMeasureDurations()`, from this box once it has been built. `measures` must be the measures
    /// of the staff that owns the box — which `Staff.measureDurations` guarantees.
    func durations(of measures: [Measure]) -> [Fraction] {
        if let built = Self.lock.withLock({ durations }) {
            return built
        }
        // Built outside the lock: two threads that miss together both walk the staff and store the same answer.
        let built = measures.effectiveMeasureDurations()
        Self.lock.withLock { durations = built }
        return built
    }
}

extension StaffTimingCache: Equatable {
    static func == (_: StaffTimingCache, _: StaffTimingCache) -> Bool {
        true
    }
}

extension Staff {
    /// `measures.effectiveMeasureDurations()`, built once per change of the staff's measures — the table every
    /// per-element timing question in this package reads.
    package var measureDurations: [Fraction] {
        timingCache.durations(of: measures)
    }
}
