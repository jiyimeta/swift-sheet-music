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

        public init(document: LayoutDocument, filteredScore: Score, hiddenStaves: Set<StaffAddress>) {
            self.document = document
            self.filteredScore = filteredScore
            self.hiddenStaves = hiddenStaves
        }
    }

    private static let queue = DispatchQueue(
        label: "SheetMusicAndroidJNI.LayoutDocumentCache",
    )
    private nonisolated(unsafe) static var storage: [Int64: Entry] = [:]

    public static func store(
        handle: Int64, document: LayoutDocument, filteredScore: Score, hiddenStaves: Set<StaffAddress>,
    ) {
        let entry = Entry(document: document, filteredScore: filteredScore, hiddenStaves: hiddenStaves)
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
