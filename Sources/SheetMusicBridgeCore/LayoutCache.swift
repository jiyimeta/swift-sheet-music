import Foundation
import SheetMusicCore
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
/// Thread safety: all reads and writes are serialized on `queue`.
/// The `nonisolated(unsafe)` annotation suppresses the Swift 6
/// global-mutable-state warning; the DispatchQueue ensures actual safety.
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

    private static let queue = DispatchQueue(
        label: "SheetMusicAndroidJNI.LayoutDocumentCache",
    )
    private nonisolated(unsafe) static var storage: [Int64: Entry] = [:]

    /// `options`/`pageWidthMM`/`pageHeightMM` default to `nativeComputeLayout`'s own `.verticalDefault` /
    /// A4 shape so callers that only need `document`/`filteredScore`/`hiddenStaves` (cursor- and
    /// anchor-frame lookups, which don't re-encode a draw program) don't have to thread values they don't
    /// use. `nativeComputeLayout` (`JNISymbols.swift`, the one production call site) always passes its real
    /// values explicitly.
    public static func store(
        handle: Int64, document: LayoutDocument, filteredScore: Score, hiddenStaves: Set<StaffAddress>,
        options: LayoutOptionsWire = .verticalDefault, pageWidthMM: Double = 210, pageHeightMM: Double = 297,
    ) {
        let entry = Entry(
            document: document, filteredScore: filteredScore, hiddenStaves: hiddenStaves,
            options: options, pageWidthMM: pageWidthMM, pageHeightMM: pageHeightMM,
        )
        queue.sync { storage[handle] = entry }
    }

    /// The cached document for `handle` (back-compat accessor for callers that only need the layout).
    public static func value(for handle: Int64) -> LayoutDocument? {
        queue.sync { storage[handle]?.document }
    }

    /// The full cache entry (document + filter context) for `handle`.
    public static func entry(for handle: Int64) -> Entry? {
        queue.sync { storage[handle] }
    }

    public static func release(_ handle: Int64) {
        queue.sync { _ = storage.removeValue(forKey: handle) }
    }
}
