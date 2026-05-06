// swiftlint:disable function_body_length file_length
import SheetMusicCore
import SheetMusicLayout
import SwiftUI

/// MuseScore-style playback cursor: a tall translucent rectangle
/// positioned at the column for the current `cursor`, spanning the
/// full vertical extent of the system that contains it (top of the
/// topmost staff to bottom of the bottommost). The cursor jumps
/// column-by-column — discrete steps — as `cursor` changes during
/// playback.
///
/// The cursor's column is one of:
///
/// * `.item(id)` — sits exactly on the chord / rest's notehead
///   column (existing behavior).
/// * `.beat(measure, tick)` — sits at a metric beat in between
///   chord onsets, with X linearly interpolated between the
///   bracketing chord / rest columns. Lets the cursor advance on
///   beats 2 / 3 / 4 even when a held half note covers them.
///
/// The host typically owns `currentCursor` published by
/// `PlaybackEngine` and feeds it in here. Returns an empty view
/// when the column can't be resolved (e.g. mid-render layout swap),
/// so it's safe to render unconditionally inside `ScoreView`'s
/// overlay.
@available(macOS 15.0, iOS 16.0, *)
public struct PlaybackCursorView: View {
    private let cursor: ScoreCursor?
    private let document: LayoutDocument
    private let score: Score
    private let color: Color

    public init(
        cursor: ScoreCursor?,
        document: LayoutDocument,
        score: Score,
        color: Color = Color.blue.opacity(0.15)
    ) {
        self.cursor = cursor
        self.document = document
        self.score = score
        self.color = color
    }

    public var body: some View {
        if let cursor,
           let frame = document.cursorFrame(for: cursor, in: score)
        {
            Rectangle()
                .fill(color)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(false)
        }
    }
}

@available(macOS 15.0, iOS 16.0, *)
extension LayoutDocument {
    /// Bounding rectangle (document coords) for the playback cursor
    /// when it's parked on `cursor`. Y span covers every staff in
    /// the system containing the column. Returns `nil` when the
    /// column can't be located (e.g. ID stale after a score swap, or
    /// beat tick out of range).
    public func cursorFrame(
        for cursor: ScoreCursor, in score: Score
    ) -> CGRect? {
        switch cursor {
        case let .item(id):
            return itemFrame(id)
        case let .beat(measureIndex, tickInMeasure):
            return beatFrame(
                measureIndex: measureIndex,
                tickInMeasure: tickInMeasure,
                score: score
            )
        }
    }

    private func itemFrame(_ id: ScoreItemID) -> CGRect? {
        for system in systems {
            let topY = system.origin.y
                + (system.staffOrigins.first?.y ?? 0)
            let bottomY = system.origin.y
                + (system.staffOrigins.last?.y ?? 0)
                + metrics.staffHeight
            for measure in system.measures {
                if let x = itemX(id, in: measure) {
                    let absX = system.origin.x + measure.origin.x + x
                    let halfW = metrics.sp * 0.4
                    return CGRect(
                        x: absX - halfW,
                        y: topY,
                        width: halfW * 2,
                        height: bottomY - topY
                    )
                }
            }
        }
        return nil
    }

    private func beatFrame(
        measureIndex: Int,
        tickInMeasure: Int,
        score: Score
    ) -> CGRect? {
        for system in systems {
            let topY = system.origin.y
                + (system.staffOrigins.first?.y ?? 0)
            let bottomY = system.origin.y
                + (system.staffOrigins.last?.y ?? 0)
                + metrics.staffHeight
            for measure in system.measures
                where measure.measureIndex == measureIndex
            {
                guard let xInMeasure = beatXInMeasure(
                    tickInMeasure: tickInMeasure,
                    measureIndex: measureIndex,
                    layoutMeasure: measure,
                    score: score
                )
                else { return nil }
                let absX = system.origin.x
                    + measure.origin.x
                    + xInMeasure
                let halfW = metrics.sp * 0.4
                return CGRect(
                    x: absX - halfW,
                    y: topY,
                    width: halfW * 2,
                    height: bottomY - topY
                )
            }
        }
        return nil
    }

    /// Linearly interpolate the cursor's measure-local X for a beat
    /// tick, using the bracketing chord / rest columns as anchors.
    /// Walks the score's voices for the measure to learn each
    /// element's tick, then matches them up against the layout's X
    /// positions.
    private func beatXInMeasure(
        tickInMeasure target: Int,
        measureIndex: Int,
        layoutMeasure: LayoutMeasure,
        score: Score
    ) -> CGFloat? {
        var ticksToX: [Int: CGFloat] = [:]
        let division = score.division
        for (address, staff) in score.allStaves {
            guard measureIndex < staff.measures.count else { continue }
            let measure = staff.measures[measureIndex]
            for (voiceIdx, voice) in measure.voices.enumerated() {
                var t = 0
                for (elemIdx, el) in voice.elements.enumerated() {
                    switch el {
                    case let .chord(chord) where !chord.notes.isEmpty:
                        let nid = NoteID(
                            staff: address,
                            measureIndex: measureIndex,
                            voiceIndex: voiceIdx,
                            elementIndex: elemIdx,
                            noteIndexInChord: 0
                        )
                        if ticksToX[t] == nil,
                           let x = itemX(.note(nid), in: layoutMeasure)
                        {
                            ticksToX[t] = x
                        }
                        t += chord.duration.ticks(division: division)
                    case let .chord(rest):
                        // Empty chord = rest.
                        let rid = RestID(
                            staff: address,
                            measureIndex: measureIndex,
                            voiceIndex: voiceIdx,
                            elementIndex: elemIdx
                        )
                        // Skip whole-note rests: they're centered in
                        // the measure, not at their tick column
                        // (`LayoutEngine+Placement.swift`'s
                        // `isWholeRest` branch), so their X would
                        // anchor the cursor mid-bar instead of at
                        // tick 0. Mirrors the same skip done in
                        // `PlaybackTimeline`'s pending build.
                        let restTicks = rest.duration.ticks(division: division)
                        let isWholeNoteRest = restTicks >= 4 * division
                        if !isWholeNoteRest, ticksToX[t] == nil,
                           let x = itemX(.rest(rid), in: layoutMeasure)
                        {
                            ticksToX[t] = x
                        }
                        t += restTicks
                    default:
                        break
                    }
                }
            }
        }

        let sorted = ticksToX.keys.sorted()
        // Snap onto an existing column if there is one.
        if let exact = ticksToX[target] { return exact }
        // Find brackets: largest tick <= target, smallest tick > target.
        guard var leftTick = sorted.first else { return nil }
        var rightTick: Int?
        for tick in sorted {
            if tick <= target { leftTick = tick } else { rightTick = tick; break }
        }
        guard let leftX = ticksToX[leftTick] else { return nil }
        if let rightTick, let rightX = ticksToX[rightTick],
           rightTick > leftTick
        {
            let frac = CGFloat(target - leftTick)
                / CGFloat(rightTick - leftTick)
            return leftX + frac * (rightX - leftX)
        }
        // No column to the right of target — interpolate to the
        // measure's right edge so a held final note still gets a
        // moving cursor on its remaining beats.
        let endX = layoutMeasure.width
        if target > leftTick {
            // Use the measure's tick length (sum of voice 0
            // durations) to scale the remaining-beat offset.
            let measureTicks = measureTickLength(
                measureIndex: measureIndex, score: score, division: division
            )
            if measureTicks > leftTick {
                let frac = CGFloat(target - leftTick)
                    / CGFloat(measureTicks - leftTick)
                return leftX + frac * (endX - leftX)
            }
        }
        return leftX
    }

    private func itemX(
        _ id: ScoreItemID, in measure: LayoutMeasure
    ) -> CGFloat? {
        switch id {
        case let .note(target):
            for el in measure.elements {
                if case let .chord(notes, _, _, _, _, _, _, _) = el,
                   let n = notes.first(where: {
                       $0.noteID == target
                   })
                {
                    return n.origin.x
                }
            }
        case let .rest(target):
            for el in measure.elements {
                if case let .rest(_, p, _, rid, _) = el,
                   rid == target
                {
                    return p.x
                }
            }
        case .tuplet:
            // Playback cursor never positions on a tuplet bracket
            // — a tuplet selection is rest-of-the-tuplet shorthand,
            // not a tick anchor.
            return nil
        }
        return nil
    }
}

private func measureTickLength(
    measureIndex: Int, score: Score, division: Int
) -> Int {
    guard let voice0 = score.allStaves.first?.staff
        .measures[safe: measureIndex]?.voices.first
    else { return 0 }
    var t = 0
    for el in voice0.elements {
        switch el {
        case let .chord(c): t += c.duration.ticks(division: division)
        default: break
        }
    }
    return t
}

extension Array {
    fileprivate subscript(safe i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}
