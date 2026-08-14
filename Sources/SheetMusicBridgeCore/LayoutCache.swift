import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout

/// Caches the most-recent layout `Entry` keyed by `scoreHandle`, populated
/// each time `nativeComputeLayout` runs. Used by `nativeCursorFrame` to
/// resolve a ScoreCursor → CGRect without recomputing layout on every poll.
///
/// The entry also carries the *filtered* score and the hidden-staff set the
/// document was laid out from, so the cursor bridge can translate a
/// full-score engine cursor into the filtered layout's coordinate space (the
/// document's `NoteID` / `RestID` keys are filtered addresses; a cursor on a
/// hidden staff resolves to a `.beat` fallback). Without these a cursor on or
/// after a hidden staff fails the layout lookup and disappears during playback.
///
/// Thread safety: all reads and writes are serialized on `lock`.
/// The `nonisolated(unsafe)` annotation suppresses the Swift 6
/// global-mutable-state warning; `SerialLock` ensures actual safety.
public enum LayoutDocumentCache {
    /// One handle's cached layout plus the filter context it was built from.
    public struct Entry {
        public let document: LayoutDocument
        /// The score after `applying(clefOverrides:).filtered(hidingStaves:)` — its addresses match the
        /// document's keys, so cursor `.beat` interpolation snaps onto the surviving visible columns.
        public let filteredScore: Score
        /// The hidden-staff set used for this layout; drives the full→filtered cursor translation.
        public let hiddenStaves: Set<StaffAddress>
        /// The exact `LayoutOptionsWire` `nativeComputeLayout` was called with — carries the layout mode
        /// (`.vertical`/`.horizontal`/`.page`) and the break policy a re-encode needs to reproduce the same
        /// page assembly `LayoutBridge.encodePages(document:options:pageWidthMM:pageHeightMM:tint:)` used the
        /// first time, without redoing `LayoutEngine.layout`.
        public let options: LayoutOptionsWire
        /// The exact `pageWidthMM`/`pageHeightMM` `nativeComputeLayout` was called with. `.vertical` mode's
        /// page width is the caller's viewport (not recoverable from `document.size`, which is the — usually
        /// narrower — rendered content extent), and `.page` mode's fixed per-page size drives its pagination
        /// cut; both must be replayed verbatim for a re-encode to match byte-for-byte.
        public let pageWidthMM: Double
        public let pageHeightMM: Double

        public init(
            document: LayoutDocument, filteredScore: Score, hiddenStaves: Set<StaffAddress>,
            options: LayoutOptionsWire, pageWidthMM: Double, pageHeightMM: Double,
        ) {
            self.document = document
            self.filteredScore = filteredScore
            self.hiddenStaves = hiddenStaves
            self.options = options
            self.pageWidthMM = pageWidthMM
            self.pageHeightMM = pageHeightMM
        }
    }

    private static let lock = SerialLock(
        label: "SheetMusicBridgeCore.LayoutDocumentCache",
    )
    private nonisolated(unsafe) static var storage: [Int64: Entry] = [:]
    private nonisolated(unsafe) static var generations: [Int64: Int64] = [:]

    /// How many times the score behind `handle` has been replaced under it.
    ///
    /// A layout compute is long, reads the score at its start, and writes this cache at its end — without the
    /// edit lock (see `EditSessionBridge`'s threading note). An edit landing in between replaces the score and
    /// clears the cache, and the compute then files a document describing a score that no longer exists. Passing
    /// this value into `store(handle:computedFromGeneration:…)` is what lets the write notice.
    ///
    /// Read it *before* reading the score, so a generation bump that happens between the two reads is counted
    /// rather than missed: seeing an older generation than the score is safe (a needless refusal), seeing a newer
    /// one is the bug.
    public static func scoreGeneration(for handle: Int64) -> Int64 {
        lock.withLock { generations[handle] ?? 0 }
    }

    /// Drops the cached layout **and** marks the handle's score as changed.
    ///
    /// This is the edit path's invalidation, distinct from `release(_:)`: the handle lives on, so the generation
    /// has to survive and advance rather than disappear. Without the bump, a compute already in flight would
    /// re-file its stale document into the cache this call just emptied.
    public static func invalidate(_ handle: Int64) {
        lock.withLock {
            storage.removeValue(forKey: handle)
            generations[handle] = (generations[handle] ?? 0) + 1
        }
    }

    /// `options`/`pageWidthMM`/`pageHeightMM` default to `nativeComputeLayout`'s own `.verticalDefault` /
    /// A4 shape so callers that only need `document`/`filteredScore`/`hiddenStaves` (cursor- and
    /// anchor-frame lookups, which don't re-encode a draw program) don't have to thread values they don't
    /// use. `nativeComputeLayout` (`JNISymbols.swift`, the one production call site) always passes its real
    /// values explicitly.
    ///
    /// `computedFromGeneration` is the value `scoreGeneration(for:)` returned before the layout was computed.
    /// When it no longer matches, the score changed while the layout was being built and the document describes
    /// the old one: the write is refused and the cache stays empty, so every reader that resolves geometry
    /// against it (`nativeEditingHitTest` above all, whose answer becomes the *target of an edit*) gets "no
    /// layout" rather than a confident wrong answer. The recompute that the edit already requested repopulates
    /// it. `nil` skips the check, for callers with no compute window to race — the tests, which install a
    /// document directly.
    ///
    /// Returns whether the entry was stored.
    @discardableResult
    public static func store(
        handle: Int64, document: LayoutDocument, filteredScore: Score, hiddenStaves: Set<StaffAddress>,
        options: LayoutOptionsWire = .verticalDefault, pageWidthMM: Double = 210, pageHeightMM: Double = 297,
        computedFromGeneration: Int64? = nil,
    ) -> Bool {
        let entry = Entry(
            document: document, filteredScore: filteredScore, hiddenStaves: hiddenStaves,
            options: options, pageWidthMM: pageWidthMM, pageHeightMM: pageHeightMM,
        )
        return lock.withLock {
            if let computedFromGeneration, (generations[handle] ?? 0) != computedFromGeneration { return false }
            storage[handle] = entry
            return true
        }
    }

    /// The cached document for `handle` (back-compat accessor for callers that only need the layout).
    public static func value(for handle: Int64) -> LayoutDocument? {
        lock.withLock { storage[handle]?.document }
    }

    /// The full cache entry (document + filter context) for `handle`.
    public static func entry(for handle: Int64) -> Entry? {
        lock.withLock { storage[handle] }
    }

    /// Forgets the handle entirely — the score behind it is gone, not merely changed.
    ///
    /// The generation goes with it so a recycled handle id starts from zero. A compute still in flight against
    /// the released handle then finds a generation that no longer matches the one it captured and declines to
    /// file its document, which is what should happen: it laid out a score that has since been freed.
    public static func release(_ handle: Int64) {
        lock.withLock {
            storage.removeValue(forKey: handle)
            generations.removeValue(forKey: handle)
        }
    }
}
