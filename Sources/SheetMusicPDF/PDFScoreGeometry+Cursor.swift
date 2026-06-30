import CoreGraphics
import Foundation
import SheetMusicCore

extension PDFScoreGeometry {
    /// Full-height playback-cursor bar for `cursor`, drawn on the original
    /// PDF. The x is the item's column (or the interpolated beat x); the y
    /// grows to span the whole system containing the column — mirroring how
    /// `LayoutDocument.cursorFrame(for:in:)` spans every staff in the
    /// system. Returns `nil` when the column can't be located.
    public func cursorRect(
        for cursor: ScoreCursor, in score: Score,
    ) -> PDFElementRect? {
        guard let column = columnRect(for: cursor, in: score) else {
            return nil
        }
        let page = column.pageIndex
        let yRect = systemRect(onPage: page, containing: column.rect)?.rect
            ?? column.rect
        let width = max(column.rect.width, 6)
        let x = column.rect.midX - width / 2
        return PDFElementRect(
            pageIndex: page,
            rect: CGRect(
                x: x, y: yRect.minY, width: width, height: yRect.height,
            ),
        )
    }

    /// The thin column (x + page) for a cursor before it's grown to system
    /// height: a snapped item rect, or the interpolated beat position.
    private func columnRect(
        for cursor: ScoreCursor, in score: Score,
    ) -> PDFElementRect? {
        switch cursor {
        case let .item(id):
            return rect(for: id)
        case let .beat(measureIndex, tickInMeasure):
            return beatColumn(
                measureIndex: measureIndex,
                tickInMeasure: tickInMeasure,
                score: score,
            )
        }
    }
}

// MARK: - Beat interpolation (mirrors CursorFrame.beatXInMeasure)

extension PDFScoreGeometry {
    private func beatColumn(
        measureIndex: Int, tickInMeasure target: Int, score: Score,
    ) -> PDFElementRect? {
        var ticksToX: [Int: CGFloat] = [:]
        var anchorPage: Int?
        var cell: CGRect?
        let division = score.division

        for (address, staff) in score.allStaves {
            guard measureIndex < staff.measures.count else { continue }
            let durations = staff.measures.effectiveMeasureDurations()
            let md = durations[measureIndex]
            let measure = staff.measures[measureIndex]
            if let cr = measureRect(staff: address, measureIndex: measureIndex) {
                if cell == nil { cell = cr.rect; anchorPage = cr.pageIndex }
            }
            for (voiceIdx, voice) in measure.voices.enumerated() {
                var t = 0
                for (elemIdx, el) in voice.elements.enumerated() {
                    switch el {
                    case let .chord(chord) where !chord.notes.isEmpty:
                        let nid = NoteID(
                            staff: address, measureIndex: measureIndex,
                            voiceIndex: voiceIdx, elementIndex: elemIdx,
                            noteIndexInChord: 0,
                        )
                        if ticksToX[t] == nil, let r = itemRects[.note(nid)] {
                            ticksToX[t] = r.rect.midX
                            if anchorPage == nil { anchorPage = r.pageIndex }
                        }
                        t += chord.duration.resolved(in: md)
                            .ticks(division: division)
                    case let .chord(rest):
                        let rid = RestID(
                            staff: address, measureIndex: measureIndex,
                            voiceIndex: voiceIdx, elementIndex: elemIdx,
                        )
                        let restTicks = rest.duration.resolved(in: md)
                            .ticks(division: division)
                        // Whole-note rests render centered, not at their
                        // tick column — skip as an anchor (mirrors
                        // PlaybackTimeline / CursorFrame).
                        if restTicks < 4 * division, ticksToX[t] == nil,
                           let r = itemRects[.rest(rid)]
                        {
                            ticksToX[t] = r.rect.midX
                            if anchorPage == nil { anchorPage = r.pageIndex }
                        }
                        t += restTicks
                    default:
                        break
                    }
                }
            }
        }

        guard let page = anchorPage, let cellRect = cell,
              let x = interpolateX(
                  ticksToX: ticksToX, target: target,
                  measureIndex: measureIndex, score: score, cell: cellRect,
              )
        else { return nil }
        return PDFElementRect(
            pageIndex: page,
            rect: CGRect(x: x, y: cellRect.minY, width: 0, height: cellRect.height),
        )
    }

    private func interpolateX(
        ticksToX: [Int: CGFloat], target: Int,
        measureIndex: Int, score: Score, cell: CGRect,
    ) -> CGFloat? {
        if let exact = ticksToX[target] { return exact }
        let sorted = ticksToX.keys.sorted()
        guard var leftTick = sorted.first else {
            // No anchors (all-whole-rest measure): spread beats linearly
            // across the cell so the cursor still advances.
            let measureTicks = measureTickLength(
                measureIndex: measureIndex, score: score,
            )
            guard measureTicks > 0 else { return nil }
            let frac = max(0, min(1, CGFloat(target) / CGFloat(measureTicks)))
            return cell.minX + frac * cell.width
        }
        var rightTick: Int?
        for tick in sorted {
            if tick <= target { leftTick = tick } else { rightTick = tick; break }
        }
        guard let leftX = ticksToX[leftTick] else { return nil }
        if let rightTick, let rightX = ticksToX[rightTick], rightTick > leftTick {
            let frac = CGFloat(target - leftTick) / CGFloat(rightTick - leftTick)
            return leftX + frac * (rightX - leftX)
        }
        // Past the last column: interpolate toward the cell's right edge.
        let measureTicks = measureTickLength(
            measureIndex: measureIndex, score: score,
        )
        if target > leftTick, measureTicks > leftTick {
            let frac = CGFloat(target - leftTick) / CGFloat(measureTicks - leftTick)
            return leftX + frac * (cell.maxX - leftX)
        }
        return leftX
    }

    private func measureTickLength(measureIndex: Int, score: Score) -> Int {
        guard let firstStaff = score.parts.first?.staves.first,
              measureIndex < firstStaff.measures.count,
              let voice0 = firstStaff.measures[measureIndex].voices.first
        else { return 0 }
        let durations = firstStaff.measures.effectiveMeasureDurations()
        let md = durations[measureIndex]
        var t = 0
        for el in voice0.elements {
            if case let .chord(c) = el {
                t += c.duration.resolved(in: md).ticks(division: score.division)
            }
        }
        return t
    }
}
