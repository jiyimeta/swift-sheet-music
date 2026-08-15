#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

extension LayoutDocument {
    /// Bounding rectangle (document coords) for the playback cursor
    /// when it's parked on `cursor`. Y span covers every staff in
    /// the system containing the column. Returns `nil` when the
    /// column can't be located (e.g. ID stale after a score swap, or
    /// beat tick out of range).
    public func cursorFrame(
        for cursor: ScoreCursor, in score: Score,
    ) -> CGRect? {
        switch cursor {
        case let .item(id):
            // A measure-fill rest (`NoteDuration.measure`) renders
            // *centered* in the bar, not on its rhythmic onset column
            // (`LayoutEngine+Placement`'s `isMeasureRest` branch). Parking
            // the playback cursor on that centered glyph would sit it at
            // the measure midpoint even though the rest's onset — and the
            // tick the engine seeks to (`itemTicks[.rest]` = measure start)
            // — is beat 1. Redirect to the beat-1 column so the visible
            // cursor matches the audio position (and any beat-1 chord on
            // another staff). Mirrors the whole-rest skip already applied
            // in `beatXInMeasure` and `PlaybackTimeline`, closing the same
            // gap on the `.item` frame path (a tap on the rest glyph).
            if case let .rest(restID) = id, isMeasureFillRest(restID) {
                return beatFrame(
                    measureIndex: restID.measureIndex,
                    tickInMeasure: 0,
                    score: score,
                )
            }
            return itemFrame(id)
        case let .beat(measureIndex, tickInMeasure):
            return beatFrame(
                measureIndex: measureIndex,
                tickInMeasure: tickInMeasure,
                score: score,
            )
        }
    }

    /// True when `restID` resolves to a measure-fill rest
    /// (`NoteDuration.measure`) in the laid-out score — the kind
    /// `LayoutEngine+Placement` centers in the bar. Such a rest's layout
    /// `origin.x` is the measure midpoint, not its tick-0 column, so the
    /// playback cursor must not anchor to it directly.
    private func isMeasureFillRest(_ restID: RestID) -> Bool {
        for system in systems {
            for measure in system.measures {
                for element in measure.elements {
                    if case let .rest(duration, _, _, rid, _) = element,
                       rid == restID
                    {
                        return duration == .measure
                    }
                }
            }
        }
        return false
    }

    private func itemFrame(_ id: ScoreItemID) -> CGRect? {
        for system in systems {
            // Same span as the system's own left-edge vertical: the end
            // staves' drawn extent, with MuseScore's ±2 sp one-line
            // case. Not `metrics.staffHeight` (the five-line reference,
            // 4 sp too tall) nor the drawn height (0 on one line).
            guard let span = system.systemStartBarLine else { continue }
            let topY = system.origin.y + span.top
            let bottomY = system.origin.y + span.bottom
            for measure in system.measures {
                if let x = itemX(id, in: measure) {
                    let absX = system.origin.x + measure.origin.x + x
                    let halfW = metrics.sp * 0.4
                    return CGRect(
                        x: absX - halfW,
                        y: topY,
                        width: halfW * 2,
                        height: bottomY - topY,
                    )
                }
            }
        }
        return nil
    }

    private func beatFrame(
        measureIndex: Int,
        tickInMeasure: Int,
        score: Score,
    ) -> CGRect? {
        for system in systems {
            // Same span as `itemFrame`; see the note there.
            guard let span = system.systemStartBarLine else { continue }
            let topY = system.origin.y + span.top
            let bottomY = system.origin.y + span.bottom
            for measure in system.measures {
                let xInMeasure: CGFloat?
                if let span = measure.multiMeasureRest,
                   measure.measureIndex <= measureIndex,
                   measureIndex < measure.measureIndex + span
                {
                    // Collapsed multi-measure rest: the H-bar replaces
                    // `span` source measures. Spread their cumulative
                    // beat ticks linearly across the bar's width so
                    // the cursor still moves per beat (at 1/span of
                    // normal pace) instead of disappearing for the
                    // whole H-bar.
                    xInMeasure = collapsedRestBeatX(
                        tickInMeasure: tickInMeasure,
                        targetMeasureIndex: measureIndex,
                        layoutMeasure: measure,
                        span: span,
                        score: score,
                    )
                } else if measure.measureIndex == measureIndex,
                          measure.multiMeasureRest == nil
                {
                    xInMeasure = beatXInMeasure(
                        tickInMeasure: tickInMeasure,
                        measureIndex: measureIndex,
                        layoutMeasure: measure,
                        score: score,
                    )
                } else {
                    continue
                }
                guard let x = xInMeasure else { return nil }
                let absX = system.origin.x
                    + measure.origin.x
                    + x
                let halfW = metrics.sp * 0.4
                return CGRect(
                    x: absX - halfW,
                    y: topY,
                    width: halfW * 2,
                    height: bottomY - topY,
                )
            }
        }
        return nil
    }

    /// X within a collapsed multi-measure-rest H-bar for a beat tick
    /// in one of the underlying source measures. Each source measure
    /// contributes its real tick length, so a 4-measure collapse of
    /// equal-length bars advances the cursor at 1/4 the per-bar pace
    /// of an uncollapsed measure.
    private func collapsedRestBeatX(
        tickInMeasure target: Int,
        targetMeasureIndex: Int,
        layoutMeasure: LayoutMeasure,
        span: Int,
        score: Score,
    ) -> CGFloat? {
        let division = score.division
        var ticksBefore = 0
        for mi in layoutMeasure.measureIndex ..< targetMeasureIndex {
            ticksBefore += measureTickLength(
                measureIndex: mi, score: score, division: division,
            )
        }
        var totalTicks = ticksBefore
        for mi in targetMeasureIndex
            ..< (layoutMeasure.measureIndex + span)
        {
            totalTicks += measureTickLength(
                measureIndex: mi, score: score, division: division,
            )
        }
        guard totalTicks > 0 else { return nil }
        let pos = CGFloat(ticksBefore + target)
        let frac = max(0, min(1, pos / CGFloat(totalTicks)))
        return frac * layoutMeasure.width
    }

    /// Linearly interpolate the cursor's measure-local X for a beat
    /// tick, using the bracketing chord / rest columns as anchors.
    /// Walks the score's voices for the measure to learn each
    /// element's tick, then matches them up against the layout's X
    /// positions.
    private func beatXInMeasure( // swiftlint:disable:this function_body_length
        tickInMeasure target: Int,
        measureIndex: Int,
        layoutMeasure: LayoutMeasure,
        score: Score,
    ) -> CGFloat? {
        var ticksToX: [Int: CGFloat] = [:]
        let division = score.division
        for (address, staff) in score.allStaves {
            guard measureIndex < staff.measures.count else { continue }
            let measureDurations = staff.measures.effectiveMeasureDurations()
            let measureDuration = measureDurations[measureIndex]
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
                            noteIndexInChord: 0,
                        )
                        if ticksToX[t] == nil,
                           let x = itemX(.note(nid), in: layoutMeasure)
                        {
                            ticksToX[t] = x
                        }
                        t += chord.duration.resolved(in: measureDuration)
                            .ticks(division: division)
                    case let .chord(rest):
                        // Empty chord = rest.
                        let rid = RestID(
                            staff: address,
                            measureIndex: measureIndex,
                            voiceIndex: voiceIdx,
                            elementIndex: elemIdx,
                        )
                        // Skip MEASURE rests: they're centered in
                        // the measure, not at their tick column
                        // (`LayoutEngine+Placement.swift`'s
                        // `isMeasureRest` branch), so their X would
                        // anchor the cursor mid-bar instead of at
                        // tick 0. Mirrors the same skip done in
                        // `PlaybackTimeline`'s pending build.
                        //
                        // Keyed on the DURATION CASE, not on the tick
                        // count: a measure rest spans 4·division ticks
                        // only in common time, so the old
                        // `restTicks >= 4 * division` test let every
                        // SHORT bar's centered rest through — a 2/4
                        // empty bar anchored tick 0 at its center and
                        // the cursor ran backwards to the real beat-2
                        // column. A typed `.whole` rest is not skipped:
                        // it sits on its start beat and anchors fine.
                        let restTicks = rest.duration.resolved(in: measureDuration)
                            .ticks(division: division)
                        if !el.isMeasureRest, ticksToX[t] == nil,
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
        guard var leftTick = sorted.first else {
            // Every voice's content was skipped — typically a measure
            // where all voices carry only a whole-measure rest. Those
            // rests render centered (not at a tick column), so they
            // can't anchor an interpolation. Fall back to spreading
            // the beat ticks linearly across the measure's body so
            // the cursor still advances per beat instead of
            // disappearing for the whole bar — but start past any
            // leading clef / key sig / time sig so the cursor doesn't
            // sit on top of the header glyphs at the measure's left.
            let measureTicks = measureTickLength(
                measureIndex: measureIndex, score: score, division: division,
            )
            guard measureTicks > 0 else { return nil }
            let leading = leadingHeaderRightEdge(in: layoutMeasure)
            let trailing = metrics.sp
            let body = max(0, layoutMeasure.width - leading - trailing)
            let frac = max(0, min(1, CGFloat(target) / CGFloat(measureTicks)))
            return leading + frac * body
        }
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
                measureIndex: measureIndex, score: score, division: division,
            )
            if measureTicks > leftTick {
                let frac = CGFloat(target - leftTick)
                    / CGFloat(measureTicks - leftTick)
                return leftX + frac * (endX - leftX)
            }
        }
        return leftX
    }

    /// Approximate right edge of a measure's leading clef / key sig /
    /// time sig column, in measure-local coords. Mirrors the
    /// `HeaderSchedule.contentStartX` the layout engine derived when
    /// placing the measure: `clefX` baseline of `sp * 2` plus each
    /// header glyph's reserved width. Used by `beatXInMeasure`'s no-
    /// anchors fallback so the cursor doesn't sit on top of the
    /// leading glyphs in an all-whole-rest measure.
    ///
    /// Mid-measure clef / key changes also land in `elements` and would
    /// be picked up here, but they only arise after a chord — and a
    /// measure with any chord wouldn't reach this fallback in the first
    /// place, so widening the floor with them is a no-op.
    private func leadingHeaderRightEdge(in measure: LayoutMeasure) -> CGFloat {
        let sp = metrics.sp
        var rightEdge: CGFloat = sp * 2
        for el in measure.elements {
            switch el {
            case let .clef(_, origin, _):
                rightEdge = max(rightEdge, origin.x + sp * 2)
            case let .keySignature(sharps, flats, _, origin):
                let glyphs = CGFloat(max(sharps, flats))
                rightEdge = max(rightEdge, origin.x + sp * (glyphs + 1.5))
            case let .timeSignature(_, _, origin):
                rightEdge = max(rightEdge, origin.x + sp * 3.5)
            default:
                break
            }
        }
        return rightEdge
    }

    private func itemX(
        _ id: ScoreItemID, in measure: LayoutMeasure,
    ) -> CGFloat? {
        switch id {
        case let .note(target):
            for el in measure.elements {
                if case let .chord(notes, _, _, _, _, _, _, _, _, _, _) = el,
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
        case .tuplet, .clef:
            // Playback cursor never positions on a tuplet bracket
            // or a clef — these are display-only selection targets,
            // not tick anchors.
            return nil
        }
        return nil
    }
}

private func measureTickLength(
    measureIndex: Int, score: Score, division: Int,
) -> Int {
    guard let firstStaff = score.allStaves.first?.staff,
          let measure = firstStaff.measures[safe: measureIndex],
          let voice0 = measure.voices.first
    else { return 0 }
    let measureDurations = firstStaff.measures.effectiveMeasureDurations()
    let measureDuration = measureDurations[measureIndex]
    var t = 0
    for el in voice0.elements {
        switch el {
        case let .chord(c):
            t += c.duration.resolved(in: measureDuration).ticks(division: division)
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
