#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

/// A rectangle in one PDF page's coordinate space.
///
/// Coordinates are **PDF user space: y-up, origin bottom-left** — the same
/// space `RawGlyph.origin` lives in during import, and the same space
/// PDFKit's `PDFPage.bounds(for:)` / `PDFView.convert(_:from:)` use, so a
/// PDFKit overlay needs no flip. For a top-left view (UIKit / AppKit
/// flipped layer) use `flipped(pageHeight:)`.
public struct PDFElementRect: Hashable, Sendable {
    public let pageIndex: Int
    public let rect: CGRect

    public init(pageIndex: Int, rect: CGRect) {
        self.pageIndex = pageIndex
        self.rect = rect
    }

    /// Same rectangle with its y flipped for a top-left origin space of the
    /// given page height (`displayY = pageHeight - rect.maxY`).
    public func flipped(pageHeight: CGFloat) -> PDFElementRect {
        PDFElementRect(
            pageIndex: pageIndex,
            rect: CGRect(
                x: rect.minX,
                y: pageHeight - rect.maxY,
                width: rect.width,
                height: rect.height,
            ),
        )
    }
}

/// Links the elements of a `Score` reconstructed by `PDFImporter` back to
/// their geometry in the **original** imported PDF.
///
/// Index-paths here are the SAME positional identities the `Score` uses
/// (`ScoreItemID` / `NoteID` / `StaffAddress`), so this side-car plugs
/// straight into `PlaybackTimeline` / `PlaybackEngine` cursors:
///
/// - `currentCursor` (a `ScoreCursor`) → `cursorRect(for:in:)` to draw the
///   playback cursor on the displayed PDF.
/// - a tap point → `hitTest(pageIndex:point:)` → a `ScoreItemID` to feed
///   `PlaybackEngine.seek(to:)` or to look up `score[noteID]` for preview
///   playback.
///
/// Produced only by `PDFImporter.parseWithGeometry`; `PDFImporter.parse`
/// allocates none of this.
public struct PDFScoreGeometry: Sendable {
    /// Chord / rest onset rects, keyed by the SAME `ScoreItemID` that
    /// `PlaybackTimeline` emits as a cursor: a chord is keyed by its first
    /// note (`.note(NoteID(..., noteIndexInChord: 0))`) and the rect is the
    /// union of the chord's noteheads (+ stem); a rest is keyed by
    /// `.rest(RestID)` with the rest glyph's box.
    public var itemRects: [ScoreItemID: PDFElementRect]

    /// Per-note rects — one entry per surviving note in every chord, keyed
    /// by its full `NoteID`. `noteRects[id].count` over a chord equals the
    /// chord's `notes.count` (deduped survivor order).
    public var noteRects: [NoteID: PDFElementRect]

    /// Per-measure cell rects: the measure's x-range × its staff's y-line
    /// span, on the measure's page.
    public var measureRects: [MeasureCellKey: PDFElementRect]

    /// One rect per assembled system instance (its y-range × page width).
    public var systemRects: [PDFElementRect]

    /// Page sizes (PDF mediaBox), indexed by page, for display flips and
    /// clamping.
    public var pageSizes: [Int: CGSize]

    public init(
        itemRects: [ScoreItemID: PDFElementRect] = [:],
        noteRects: [NoteID: PDFElementRect] = [:],
        measureRects: [MeasureCellKey: PDFElementRect] = [:],
        systemRects: [PDFElementRect] = [],
        pageSizes: [Int: CGSize] = [:],
    ) {
        self.itemRects = itemRects
        self.noteRects = noteRects
        self.measureRects = measureRects
        self.systemRects = systemRects
        self.pageSizes = pageSizes
    }

    /// Key identifying one measure cell on a specific staff.
    public struct MeasureCellKey: Hashable, Sendable {
        public let staff: StaffAddress
        public let measureIndex: Int

        public init(staff: StaffAddress, measureIndex: Int) {
            self.staff = staff
            self.measureIndex = measureIndex
        }
    }
}

// MARK: - Lookups

extension PDFScoreGeometry {
    /// Rect for a selectable item. For a chord this returns the union
    /// (chord-level) rect; pass a `NoteID` to `rect(for:)` for a single
    /// notehead. A `.note` whose chord-level key is absent falls back to
    /// the per-note rect, then to the chord's representative note.
    public func rect(for item: ScoreItemID) -> PDFElementRect? {
        if let r = itemRects[item] { return r }
        guard case let .note(id) = item else { return nil }
        if let r = noteRects[id] { return r }
        let lead = NoteID(
            staff: id.staff,
            measureIndex: id.measureIndex,
            voiceIndex: id.voiceIndex,
            elementIndex: id.elementIndex,
            noteIndexInChord: 0,
        )
        return itemRects[.note(lead)]
    }

    /// Rect for a single notehead, falling back to the chord-level rect.
    public func rect(for note: NoteID) -> PDFElementRect? {
        noteRects[note] ?? rect(for: .note(note))
    }

    /// Cell rect for one measure on one staff.
    public func measureRect(
        staff: StaffAddress, measureIndex: Int,
    ) -> PDFElementRect? {
        measureRects[MeasureCellKey(staff: staff, measureIndex: measureIndex)]
    }

    /// The system rect on `page` that vertically contains `rect` (the first
    /// match in assembly order). Used to grow a column into a full-height
    /// cursor bar and for auto-scroll.
    public func systemRect(
        onPage page: Int, containing rect: CGRect,
    ) -> PDFElementRect? {
        systemRects.first {
            $0.pageIndex == page && $0.rect.intersects(rect)
        }
    }

    /// The system rect containing an item's onset rect.
    public func systemRect(containing item: ScoreItemID) -> PDFElementRect? {
        guard let r = rect(for: item) else { return nil }
        return systemRect(onPage: r.pageIndex, containing: r.rect)
    }
}

// MARK: - Hit-testing (PDF point → Score element)

extension PDFScoreGeometry {
    /// Resolve a tap at `point` (PDF page coords, y-up) on `pageIndex` to a
    /// `ScoreItemID`. Returns the precise `.note(NoteID)` for a notehead or
    /// `.rest(RestID)` for a rest: a containing rect first, else the
    /// nearest rect center within `tolerance`, else the leftmost item of
    /// the measure cell under the point (so a tap anywhere in a bar still
    /// seeks to that bar's start).
    public func hitTest(
        pageIndex: Int, point: CGPoint, tolerance: CGFloat = 12,
    ) -> ScoreItemID? {
        if let note = nearestNote(pageIndex: pageIndex, point: point, tolerance: tolerance) {
            return .note(note)
        }
        if let rest = nearestRest(pageIndex: pageIndex, point: point, tolerance: tolerance) {
            return rest
        }
        return leadingItemOfMeasure(pageIndex: pageIndex, point: point)
    }

    private func nearestNote(
        pageIndex: Int, point: CGPoint, tolerance: CGFloat,
    ) -> NoteID? {
        var best: NoteID?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (id, r) in noteRects where r.pageIndex == pageIndex {
            if r.rect.contains(point) { return id }
            let d = distance(from: point, to: r.rect)
            if d < bestDist { bestDist = d; best = id }
        }
        return bestDist <= tolerance ? best : nil
    }

    private func nearestRest(
        pageIndex: Int, point: CGPoint, tolerance: CGFloat,
    ) -> ScoreItemID? {
        var best: ScoreItemID?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (id, r) in itemRects where r.pageIndex == pageIndex {
            guard case .rest = id else { continue }
            if r.rect.contains(point) { return id }
            let d = distance(from: point, to: r.rect)
            if d < bestDist { bestDist = d; best = id }
        }
        return bestDist <= tolerance ? best : nil
    }

    /// Leftmost (smallest x) chord/rest item of the measure cell whose rect
    /// contains `point`.
    private func leadingItemOfMeasure(
        pageIndex: Int, point: CGPoint,
    ) -> ScoreItemID? {
        guard let cell = measureRects.first(where: {
            $0.value.pageIndex == pageIndex && $0.value.rect.contains(point)
        })?.key else { return nil }
        return itemRects
            .filter { id, _ in
                id.staff == cell.staff && id.measureIndex == cell.measureIndex
            }
            .min { $0.value.rect.minX < $1.value.rect.minX }?
            .key
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
