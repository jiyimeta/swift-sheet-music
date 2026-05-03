// swiftlint:disable function_body_length file_length
import CoreGraphics
import CoreText
import SheetMusicCore

@available(macOS 15.0, iOS 16.0, *)
extension LayoutEngine {
    /// True when consecutive same-verse syllables should be linked
    /// with a hyphen line. MuseScore draws dashes between any
    /// `begin`/`middle` and the next `middle`/`end` syllable; the
    /// boundary cases (`single→…`, `…→single`, `…→begin`) start a
    /// new word so no hyphen is drawn.
    static func connectsWithHyphen(
        prev: Syllabic, curr: Syllabic
    ) -> Bool {
        let prevContinues = prev == .begin || prev == .middle
        let currContinues = curr == .middle || curr == .end
        return prevContinues && currContinues
    }

    /// Drop one or more hyphen segments between `fromX` and `toX`
    /// at lyric-text Y. Implements the dash-count + dash-distance
    /// algorithm from MuseScore's
    /// `LyricsLayout::layoutDashes` (lyricslayout.cpp:260) using
    /// the engraving defaults from `styledef.cpp`:
    ///
    ///   * `lyricsDashMaxDistance` = 16 sp — gap between dashes
    ///   * `lyricsDashMinLength` = 0.4 sp — short gaps still get one
    ///   * `lyricsDashMaxLength` = 0.6 sp — cap on each dash length
    ///   * `lyricsDashFirstAndLastGapAreHalf` = true — outer gaps
    ///     are half-width so the dash row reads as evenly spaced
    ///     between the syllables it connects.
    ///
    /// `lyricsDashForce` is also true by default, so any positive
    /// gap below `dashMinLength` still gets one dash.
    static func emitLyricHyphens(
        fromX: CGFloat,
        toX: CGFloat,
        y: CGFloat,
        metrics: StaffMetrics,
        out: inout [LayoutElement]
    ) {
        let curLength = toX - fromX
        guard curLength > 0 else { return }
        let maxDashDistance = metrics.sp * 16
        let dashMaxLength = metrics.sp * 0.6
        // First and last gaps are half-width (matches MuseScore's
        // default), so the floor/ceil split below mirrors theirs.
        var dashCount: Int
        if curLength > maxDashDistance {
            dashCount = Int(ceil(curLength / maxDashDistance))
        } else {
            dashCount = Int(floor(curLength / maxDashDistance))
        }
        // `lyricsDashForce` default — at least one dash whenever the
        // syllables are connected, no matter how short the gap.
        if curLength > 0 {
            dashCount = max(dashCount, 1)
        }
        guard dashCount > 0 else { return }
        let dashWidth = min(curLength, dashMaxLength)
        // With `firstAndLastGapAreHalf = true`, the spacing between
        // dash centres is `curLength / dashCount`, and the first
        // centre sits at half that distance from the start.
        let dashDist = curLength / CGFloat(dashCount)
        var xCenter: CGFloat = 0
        for i in 0 ..< dashCount {
            xCenter += i == 0 ? 0.5 * dashDist : dashDist
            let centerX = fromX + xCenter
            out.append(.lyricHyphen(
                fromOrigin: CGPoint(
                    x: centerX - 0.5 * dashWidth, y: y
                ),
                toOrigin: CGPoint(
                    x: centerX + 0.5 * dashWidth, y: y
                )
            ))
        }
    }

    /// Emit the left-hand continuation rule that shows a melisma
    /// started in an earlier measure is still active here.
    static func emitMelismaContinuation(
        continuation: MelismaContinuation,
        staffMidY: CGFloat,
        tickColumns: [Int: CGFloat],
        headerContentStartX: CGFloat,
        measureWidth: CGFloat,
        metrics: StaffMetrics,
        out: inout [LayoutElement]
    ) {
        // Use the same Y the anchor rule uses — the lyric font's
        // underline level (baseline + underline offset) rather
        // than the text's vertical center.
        let lyricsY = staffMidY + metrics.sp * 4
            + CGFloat(continuation.verseIndex) * metrics.sp * 1.7
            + Self.melismaLineYOffset(sp: metrics.sp)
        // Start at x=0 (the measure's left boundary) for mid-system
        // continuations so the rule visually touches the previous
        // measure's anchor rule. When the measure carries a clef /
        // key-sig / time-sig redraw (system-start, or a mid-piece
        // change), bump past it so the rule doesn't run under the
        // glyphs. Detection: the baseline `contentStartX` for a
        // header-free measure is `sp * 2` (see `computeHeaderSchedule`'s
        // `clefX`); anything higher indicates a redraw.
        let hasHeaderRedraw = headerContentStartX > metrics.sp * 2.1
        let lineStartX: CGFloat = hasHeaderRedraw
            ? headerContentStartX
            : 0
        let withinMeasureRightX = max(
            headerContentStartX + metrics.sp,
            measureWidth - metrics.sp
        )
        let crossingRightX = measureWidth
        let sortedTicks = tickColumns.keys.sorted()
        let endX: CGFloat
        if continuation.continuesPastMeasure {
            endX = crossingRightX
        } else if let t = sortedTicks.first(
            where: { $0 >= continuation.endTick }),
            let nextX = tickColumns[t]
        {
            // Match MuseScore: extend through the end-note's
            // notehead to its right edge rather than stopping
            // just before it.
            endX = min(crossingRightX, nextX + Self.noteheadHalfExtent(sp: metrics.sp))
        } else {
            endX = withinMeasureRightX
        }
        guard endX > lineStartX + metrics.sp * 0.5 else { return }
        out.append(.lyricsMelisma(
            fromOrigin: CGPoint(x: lineStartX, y: lyricsY),
            toOrigin: CGPoint(x: endX, y: lyricsY)
        ))
    }

    /// Build a map from every non-empty lyric syllable to its
    /// "effective" melisma duration. Treats ties and melismas as
    /// independent concepts (a tie spans two notes of the same
    /// pitch played as one; a melisma is a syllable held over a
    /// stretch of voice time). The melisma length comes solely from
    /// `<ticks>`. We keep this helper so the layout pipeline still
    /// has a single place to compute the per-lyric duration and the
    /// per-measure continuation plan stays consistent.
    static func computeEffectiveMelismaTicks(
        score: Score, division: Int
    ) -> [MelismaLyricKey: Int] {
        var map: [MelismaLyricKey: Int] = [:]
        for (staffIdx, entry) in score.allStaves.enumerated() {
            let staff = entry.staff
            for (mIdx, measure) in staff.measures.enumerated() {
                for (vIdx, voice) in measure.voices.enumerated() {
                    for (eIdx, el) in voice.elements.enumerated() {
                        guard case let .chord(chord) = el else { continue }
                        for (verseIdx, lyric)
                            in chord.lyrics.enumerated()
                            where !lyric.text.isEmpty
                        {
                            map[MelismaLyricKey(
                                staffIndex: staffIdx,
                                measureIndex: mIdx,
                                voiceIndex: vIdx,
                                elementIndex: eIdx,
                                verseIndex: verseIdx
                            )] = lyric.ticks
                        }
                    }
                }
            }
        }
        return map
    }

    /// Walk the score once, identify every lyric with
    /// `ticks > chord.duration`, and compute the continuation lines
    /// that need to be drawn on every measure after the anchor.
    ///
    /// Returned shape: `result[staffIdx][measureIdx]` is the list of
    /// continuations that start elsewhere but pass through (or end
    /// in) this measure. The anchor measure itself is intentionally
    /// omitted — the per-chord `emitMelismaLine` already emits the
    /// opening segment there.
    ///
    /// Continuation semantics:
    ///
    /// * `endTick` stores the voice tick within the target measure
    ///   where the rule ends.
    /// * When `endTick` equals (or exceeds) that measure's total
    ///   voice ticks, the rule is to run through the trailing
    ///   barline — the melisma continues to the NEXT measure.
    static func computeMelismaContinuations(
        score: Score, division: Int,
        effectiveTicks: [MelismaLyricKey: Int]
    ) -> [[[MelismaContinuation]]] {
        var result: [[[MelismaContinuation]]] = score.allStaves.map { entry in
            Array(repeating: [], count: entry.staff.measures.count)
        }
        for (staffIdx, entry) in score.allStaves.enumerated() {
            let staff = entry.staff
            let voiceCount = staff.measures
                .map(\.voices.count).max() ?? 0
            for voiceIdx in 0 ..< voiceCount {
                // Pre-compute total voice ticks per measure so the
                // inner loop doesn't rescan them repeatedly.
                let tickCounts: [Int] = staff.measures.map { m in
                    guard voiceIdx < m.voices.count else { return 0 }
                    var total = 0
                    for el in m.voices[voiceIdx].elements {
                        switch el {
                        case let .chord(c):
                            total += c.duration.ticks(division: division)
                        default:
                            break
                        }
                    }
                    return total
                }
                for (mIdx, measure) in staff.measures.enumerated() {
                    guard voiceIdx < measure.voices.count else { continue }
                    var tickInMeasure = 0
                    for (eIdx, el)
                        in measure.voices[voiceIdx].elements.enumerated()
                    {
                        switch el {
                        case let .chord(c):
                            let chordTicks = c.duration
                                .ticks(division: division)
                            for (verseIdx, lyric)
                                in c.lyrics.enumerated()
                                where !lyric.text.isEmpty
                            {
                                let key = MelismaLyricKey(
                                    staffIndex: staffIdx,
                                    measureIndex: mIdx,
                                    voiceIndex: voiceIdx,
                                    elementIndex: eIdx,
                                    verseIndex: verseIdx
                                )
                                let ticks = effectiveTicks[key]
                                    ?? lyric.ticks
                                guard ticks > 0 else { continue }
                                appendContinuations(
                                    startMeasureIdx: mIdx,
                                    startTickInMeasure: tickInMeasure,
                                    lyricTicks: ticks,
                                    voiceIdx: voiceIdx,
                                    verseIdx: verseIdx,
                                    tickCounts: tickCounts,
                                    result: &result[staffIdx]
                                )
                            }
                            tickInMeasure += chordTicks
                        default:
                            break
                        }
                    }
                }
            }
        }
        return result
    }

    /// Helper for `computeMelismaContinuations`. Walks forward from
    /// the anchor chord's position, consuming voice ticks across
    /// measure boundaries, and records continuation lines on every
    /// measure AFTER the anchor.
    private static func appendContinuations(
        startMeasureIdx: Int,
        startTickInMeasure: Int,
        lyricTicks: Int,
        voiceIdx: Int,
        verseIdx: Int,
        tickCounts: [Int],
        result: inout [[MelismaContinuation]]
    ) {
        var remaining = lyricTicks
        var currentMeasure = startMeasureIdx
        var currentTick = startTickInMeasure
        while currentMeasure < tickCounts.count {
            let available = tickCounts[currentMeasure] - currentTick
            if available <= 0 {
                // Empty voice in this measure — treat the whole
                // measure as "fully covered, continues further".
                if currentMeasure > startMeasureIdx {
                    result[currentMeasure].append(MelismaContinuation(
                        voiceIndex: voiceIdx,
                        verseIndex: verseIdx,
                        endTick: tickCounts[currentMeasure],
                        continuesPastMeasure: true
                    ))
                }
                currentMeasure += 1
                currentTick = 0
                continue
            }
            // NOTE: strict `<` — when the melisma ends exactly on
            // the measure's right boundary (`remaining == available`)
            // we deliberately fall through to the full-cover branch
            // so the loop advances one more time and emits a
            // `endTick == 0` "boundary cap" on the next measure.
            // Without this, a melisma whose visual end-note is the
            // first note of the next measure gets no continuation
            // and the rule appears to stop at the barline.
            if remaining < available {
                if currentMeasure > startMeasureIdx {
                    result[currentMeasure].append(MelismaContinuation(
                        voiceIndex: voiceIdx,
                        verseIndex: verseIdx,
                        endTick: currentTick + remaining,
                        continuesPastMeasure: false
                    ))
                }
                return
            }
            remaining -= available
            // Falling through means this measure is fully covered
            // AND the loop will advance to another measure (either
            // another full-cover if `remaining > 0` or a boundary
            // cap if `remaining == 0`). In both cases the rule in
            // THIS measure has to run past the trailing barline so
            // it meets the next measure's rule without a gap —
            // hence an unconditional `true`. If the advance walks
            // off the end of the score the only visible effect is
            // the rule slightly overshooting the final barline,
            // which is acceptable for that edge case.
            if currentMeasure > startMeasureIdx {
                result[currentMeasure].append(MelismaContinuation(
                    voiceIndex: voiceIdx,
                    verseIndex: verseIdx,
                    endTick: tickCounts[currentMeasure],
                    continuesPastMeasure: true
                ))
            }
            currentMeasure += 1
            currentTick = 0
        }
    }

    /// Pixel width of the rendered lyric text at the layout's
    /// staff size. Mirrors the font used by `ScoreLayerBuilder.textLayer`
    /// for `.textMark(.lyrics, ...)` — `.system(size: sp*2.2, weight: .semibold)`.
    /// Shared with `LayoutEngine+Spacing.lyricsPairWidth` so chord spacing
    /// uses the same measurement as melisma start-x positioning.
    ///
    /// Weight matters: SwiftUI renders lyrics at `.semibold` (see
    /// `GraphicsContext+Glyph.drawExpressionText`). Measuring with the
    /// regular system font under-reports glyph advance by 5–10 %, which
    /// accumulates into adjacent-syllable overlap on tight runs of
    /// eighth notes (m. 32 "Pa ra di so!").
    static func lyricsTextWidth(
        _ text: String, sp: CGFloat
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let fontSize = sp * 2.2
        // `kCTFontWeightTrait` is in [-1, 1]. UIFont.Weight.semibold
        // maps to 0.3 — match it so CoreText returns the same glyph
        // advances SwiftUI uses.
        let traits: CFDictionary = [
            kCTFontWeightTrait: 0.3,
        ] as CFDictionary
        let attributes: CFDictionary = [
            kCTFontTraitsAttribute: traits,
            kCTFontSizeAttribute: fontSize,
        ] as CFDictionary
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes)
        let font = CTFontCreateWithFontDescriptor(descriptor, fontSize, nil)
        let attrs: CFDictionary = [
            kCTFontAttributeName: font,
        ] as CFDictionary
        guard let attrString = CFAttributedStringCreate(
            nil, text as CFString, attrs
        )
        else { return 0 }
        let line = CTLineCreateWithAttributedString(attrString)
        return CGFloat(
            CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Y offset from the lyric text's center anchor down to where
    /// the melisma rule should be drawn. MuseScore positions the
    /// rule at the lyric font's underline level, i.e. baseline +
    /// `underlinePosition`. For SwiftUI's systemFont rendered at
    /// `sp * 2.2`, the typical metrics are:
    ///
    ///   ascent  ≈ 0.85 × em ≈ 1.87 sp
    ///   descent ≈ 0.22 × em ≈ 0.47 sp
    ///   underline offset from baseline ≈ 0.10 × em ≈ 0.22 sp
    ///
    /// With anchor (0.5, 0.5) the text's center sits at
    /// `lyricsY`, so the baseline lives at
    /// `lyricsY + (ascent - descent) / 2 ≈ lyricsY + 0.7 sp` and
    /// the underline at roughly `lyricsY + 0.9 sp`. We hard-code
    /// 0.9 so the line sits where MuseScore draws it without
    /// bringing CoreText metric calls into the layout loop.
    static func melismaLineYOffset(sp: CGFloat) -> CGFloat {
        sp * 0.9
    }

    /// Emit a horizontal melisma line under the given chord's lyric.
    ///
    /// MuseScore authors specify the end-note of a melisma by
    /// dragging its right handle, which encodes the total held
    /// duration as `<ticks>` on the anchor `<Lyrics>`. We reflect
    /// that in the UI by:
    ///
    /// 1. Computing `endTick = tickCursor + lyric.ticks` — this is
    ///    the end-tick of the last covered note.
    /// 2. Finding the event at or after `endTick` in the shared
    ///    `tickColumns`. That event's x is where the NEXT syllable
    ///    / note sits, so the rule ends just before it.
    /// 3. If the melisma runs through the end of the measure (no
    ///    event at or after `endTick` in this measure), extending
    ///    the rule close to the trailing barline (`measureWidth -
    ///    sp/2`) with ~0.5 sp clearance.
    ///
    /// Cross-measure continuation (a secondary rule at the start of
    /// the next measure) is not yet emitted — within a single
    /// measure, the rule always stops at the barline.
    static func emitMelismaLine(
        chordX: CGFloat,
        lyricText: String,
        lyricTicks: Int,
        lyricsY: CGFloat,
        tickCursor: Int,
        chordTicks: Int,
        tickColumns: [Int: CGFloat],
        headerContentStartX: CGFloat,
        measureWidth: CGFloat,
        continuesPastMeasure: Bool,
        metrics: StaffMetrics,
        out: inout [LayoutElement]
    ) {
        let endTick = tickCursor + lyricTicks
        // When the melisma keeps going into the next measure, take
        // the line all the way to `measureWidth` so it meets the
        // continuation rule emitted at the next measure's x=0 and
        // there is no visible break around the barline. When it
        // stops here, leave ~sp clearance before the trailing
        // barline (which sits at `measureWidth - sp/2`).
        let withinMeasureRightX = max(
            headerContentStartX + metrics.sp,
            measureWidth - metrics.sp
        )
        let crossingRightX = measureWidth
        let sortedTicks = tickColumns.keys.sorted()
        let endX: CGFloat
        if let t = sortedTicks.first(where: { $0 >= endTick }),
           let nextX = tickColumns[t]
        {
            // Extend through the end-note's notehead to its right
            // edge — MuseScore's convention, and visually the line
            // then clearly "covers" the end note. See
            // `noteheadHalfExtent` for the constant choice.
            endX = min(crossingRightX, nextX + Self.noteheadHalfExtent(sp: metrics.sp))
        } else if continuesPastMeasure {
            endX = crossingRightX
        } else {
            endX = withinMeasureRightX
        }

        // The lyric glyph is rendered with a center anchor at
        // `chordX`. Use CoreText to measure its actual rendered
        // width — a hard-coded "X sp per character" approximation
        // overestimates Latin (creating a visible gap before the
        // rule) and underestimates CJK (running the rule under the
        // glyph). MuseScore matches the rule to the syllable's
        // bbox right edge plus a quarter-staff-space.
        let textWidth = Self.lyricsTextWidth(
            lyricText, sp: metrics.sp
        )
        let lineStartX = chordX + textWidth / 2 + metrics.sp * 0.25
        // Only emit if there is actually a visible line to draw —
        // avoids a one-pixel stub when the estimate pushes
        // `lineStartX` past `endX`.
        guard endX > lineStartX + metrics.sp * 0.5 else { return }
        out.append(.lyricsMelisma(
            fromOrigin: CGPoint(x: lineStartX, y: lyricsY),
            toOrigin: CGPoint(x: endX, y: lyricsY)
        ))
    }
}
