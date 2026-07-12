#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

/// Accumulates per-element geometry while `assembleScore` builds the
/// `Score`, then produces a `PDFScoreGeometry`. Reference type so it can be
/// threaded as a single optional through the (value-type) assembly without
/// changing any return signature — when the collector is `nil` the value
/// path runs unchanged.
///
/// Records are keyed by the flat staff **slot** during assembly (the
/// `slot → StaffAddress` mapping is only known at the very end), then
/// rewritten to `StaffAddress` in `finalize(slotToStaff:)`.
final class PDFGeometryCollector {
    /// One assembled chord or rest, before slot→address translation.
    struct ItemRecord {
        let slot: Int
        let measureIndex: Int
        let voiceIndex: Int
        let elementIndex: Int
        let isRest: Bool
        let onsetRect: PDFElementRect
        /// Aligned 1:1 with `chord.notes` (deduped survivor order); empty
        /// for a rest.
        let noteRects: [PDFElementRect]
    }

    private var items: [ItemRecord] = []
    private var measureCells: [(slot: Int, measureIndex: Int, rect: PDFElementRect)] = []
    private var systems: [PDFElementRect] = []
    private var pageSizes: [Int: CGSize] = [:]
    private var slotToStaff: [Int: StaffAddress] = [:]

    func setPageSizes(_ sizes: [Int: CGSize]) {
        pageSizes = sizes
    }

    /// The slot → `StaffAddress` mapping, known only once `assembleScore`
    /// distributes slots into parts. Consumed by `finalize`.
    func setSlotToStaff(_ map: [Int: StaffAddress]) {
        slotToStaff = map
    }

    func recordSystem(yRange: ClosedRange<CGFloat>, pageIndex: Int) {
        let width = pageSizes[pageIndex]?.width ?? 0
        systems.append(PDFGeometryRects.system(
            yRange: yRange, pageWidth: width, pageIndex: pageIndex,
        ))
    }

    func recordMeasureCell(
        slot: Int, measureIndex: Int,
        xRange: ClosedRange<CGFloat>, yLines: [CGFloat], pageIndex: Int,
    ) {
        guard let rect = PDFGeometryRects.measureCell(
            xRange: xRange, yLines: yLines, pageIndex: pageIndex,
        ) else { return }
        measureCells.append((slot, measureIndex, rect))
    }

    func recordItem(
        slot: Int, measureIndex: Int, voiceIndex: Int, elementIndex: Int,
        isRest: Bool, onsetRect: PDFElementRect, noteRects: [PDFElementRect],
    ) {
        items.append(ItemRecord(
            slot: slot, measureIndex: measureIndex, voiceIndex: voiceIndex,
            elementIndex: elementIndex, isRest: isRest,
            onsetRect: onsetRect, noteRects: noteRects,
        ))
    }

    /// Rewrite every slot-keyed record to its `StaffAddress` and emit the
    /// final immutable side-car.
    func finalize() -> PDFScoreGeometry {
        var itemRects: [ScoreItemID: PDFElementRect] = [:]
        var noteRects: [NoteID: PDFElementRect] = [:]
        var measureRects: [PDFScoreGeometry.MeasureCellKey: PDFElementRect] = [:]

        for rec in items {
            guard let staff = slotToStaff[rec.slot] else { continue }
            if rec.isRest {
                let rid = RestID(
                    staff: staff, measureIndex: rec.measureIndex,
                    voiceIndex: rec.voiceIndex, elementIndex: rec.elementIndex,
                )
                itemRects[.rest(rid)] = rec.onsetRect
            } else {
                for (k, r) in rec.noteRects.enumerated() {
                    let nid = NoteID(
                        staff: staff, measureIndex: rec.measureIndex,
                        voiceIndex: rec.voiceIndex, elementIndex: rec.elementIndex,
                        noteIndexInChord: k,
                    )
                    noteRects[nid] = r
                }
                let lead = NoteID(
                    staff: staff, measureIndex: rec.measureIndex,
                    voiceIndex: rec.voiceIndex, elementIndex: rec.elementIndex,
                    noteIndexInChord: 0,
                )
                itemRects[.note(lead)] = rec.onsetRect
            }
        }
        for cell in measureCells {
            guard let staff = slotToStaff[cell.slot] else { continue }
            measureRects[.init(staff: staff, measureIndex: cell.measureIndex)] = cell.rect
        }

        return PDFScoreGeometry(
            itemRects: itemRects,
            noteRects: noteRects,
            measureRects: measureRects,
            systemRects: systems,
            pageSizes: pageSizes,
        )
    }
}

// MARK: - Rect construction helpers (PDF page coords, y-up)

enum PDFGeometryRects {
    /// Box for a notehead / rest glyph. SMuFL note/rest glyphs anchor at the
    /// left edge with the staff-position y at the glyph origin, so the box
    /// is `advance` wide and ~`spatium` tall, vertically centered on
    /// `origin.y`.
    static func glyphBox(
        origin: CGPoint, advance: CGFloat, spatium: CGFloat, pageIndex: Int,
    ) -> PDFElementRect {
        let h = max(spatium * 1.1, 4)
        let w = max(advance, spatium)
        return PDFElementRect(
            pageIndex: pageIndex,
            rect: CGRect(x: origin.x, y: origin.y - h / 2, width: w, height: h),
        )
    }

    /// Union of same-page rects (chord = its noteheads, optionally + stem).
    /// Returns the first rect's page; rects on other pages are ignored
    /// (a chord's noteheads always share a page).
    static func union(_ rects: [PDFElementRect]) -> PDFElementRect? {
        guard let first = rects.first else { return nil }
        var box = first.rect
        for r in rects where r.pageIndex == first.pageIndex {
            box = box.union(r.rect)
        }
        return PDFElementRect(pageIndex: first.pageIndex, rect: box)
    }

    /// Measure cell: x-range × staff y-line span.
    static func measureCell(
        xRange: ClosedRange<CGFloat>, yLines: [CGFloat], pageIndex: Int,
    ) -> PDFElementRect? {
        guard let lo = yLines.min(), let hi = yLines.max(), hi > lo else {
            return nil
        }
        return PDFElementRect(
            pageIndex: pageIndex,
            rect: CGRect(
                x: xRange.lowerBound, y: lo,
                width: xRange.upperBound - xRange.lowerBound, height: hi - lo,
            ),
        )
    }

    /// System rect: y-range × full page width.
    static func system(
        yRange: ClosedRange<CGFloat>, pageWidth: CGFloat, pageIndex: Int,
    ) -> PDFElementRect {
        PDFElementRect(
            pageIndex: pageIndex,
            rect: CGRect(
                x: 0, y: yRange.lowerBound,
                width: pageWidth, height: yRange.upperBound - yRange.lowerBound,
            ),
        )
    }
}
