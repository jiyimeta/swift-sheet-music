import Foundation
import SheetMusicLayout

/// Caches the most-recent `LayoutDocument` keyed by `scoreHandle`, populated
/// each time `nativeComputeLayout` runs. Used by `nativeCursorFrame` to
/// resolve a ScoreCursor → CGRect without recomputing layout on every poll.
///
/// Thread safety: all reads and writes are serialized on `queue`.
/// The `nonisolated(unsafe)` annotation suppresses the Swift 6
/// global-mutable-state warning; the DispatchQueue ensures actual safety.
public enum LayoutDocumentCache {
    private static let queue = DispatchQueue(
        label: "SheetMusicAndroidJNI.LayoutDocumentCache",
    )
    private nonisolated(unsafe) static var storage: [Int64: LayoutDocument] = [:]

    public static func store(handle: Int64, document: LayoutDocument) {
        queue.sync { storage[handle] = document }
    }

    public static func value(for handle: Int64) -> LayoutDocument? {
        queue.sync { storage[handle] }
    }

    public static func release(_ handle: Int64) {
        queue.sync { _ = storage.removeValue(forKey: handle) }
    }
}
