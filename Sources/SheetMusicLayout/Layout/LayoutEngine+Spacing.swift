// swiftlint:disable file_length
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    /// Per-measure shared header layout. All staves in a multi-staff
    /// system use the same x-positions for clef / key sig / time sig
    /// so that a drum or tab staff (which has no key signature) still
    /// places its time signature at the same x as a pitched staff that
    /// does. Without this, drum/tab time signatures would slide left
    /// and break vertical alignment across the system.
    struct HeaderSchedule: Equatable {
        let clefX: CGFloat
        let keySigX: CGFloat
        let timeSigX: CGFloat
        let contentStartX: CGFloat
    }

    /// Compute the shared header schedule for `measureIdx` across all
    /// staves. Each column's width is the max width consumed by any
    /// staff that carries that element, so staves lacking an element
    /// simply skip its slot (empty visual space).
    ///
    /// `synthesizeKeySigForAllStaves` + `activeKeys` reserve header
    /// width for a key signature even when the measure has no literal
    /// `<KeySig>` — used at the start of continuation systems to
    /// redraw the currently active key.
    static func computeHeaderSchedule(
        measureIdx: Int,
        staves: [Staff],
        metrics: StaffMetrics,
        synthesizeClefForAllStaves: Bool,
        synthesizeKeySigForAllStaves: Bool = false,
        activeKeys: [Int]? = nil,
    ) -> HeaderSchedule {
        var clefWidth: CGFloat = 0
        var keySigWidth: CGFloat = 0
        var timeSigWidth: CGFloat = 0

        for (idx, staff) in staves.enumerated() {
            guard measureIdx < staff.measures.count else { continue }
            let measure = staff.measures[measureIdx]
            // On the first system, every staff draws a clef (either
            // explicit or synthesized). Ensure the clef column is sized
            // even when no staff has a literal <Clef>.
            if synthesizeClefForAllStaves {
                clefWidth = max(clefWidth, metrics.sp * 2)
            }
            // When a continuation system synthesises the active key
            // signature, reserve width based on that staff's carried
            // key — even if the measure itself has no literal
            // <KeySig> element.
            if synthesizeKeySigForAllStaves,
               let keys = activeKeys,
               idx < keys.count,
               keys[idx] != 0
            {
                keySigWidth = max(
                    keySigWidth,
                    metrics.sp * (CGFloat(abs(keys[idx])) + 1.5),
                )
            }
            let leading = measure.voices.first?.elements ?? []
            for el in leading {
                var stop = false
                switch el {
                case .clef:
                    clefWidth = max(clefWidth, metrics.sp * 2)
                case let .keySignature(k):
                    keySigWidth = max(
                        keySigWidth,
                        metrics.sp * (CGFloat(abs(k.concertKey)) + 1.5),
                    )
                case .timeSignature:
                    timeSigWidth = max(timeSigWidth, metrics.sp * 3)
                case .chord:
                    stop = true
                default:
                    break
                }
                if stop { break }
            }
        }

        let clefX = metrics.sp * 2
        let keySigX = clefX + clefWidth
        let timeSigX = keySigX + keySigWidth
        let contentStartX = timeSigX + timeSigWidth
            + (timeSigWidth > 0 ? metrics.sp * 0.5 : 0)
        return HeaderSchedule(
            clefX: clefX,
            keySigX: keySigX,
            timeSigX: timeSigX,
            contentStartX: contentStartX,
        )
    }

    /// Width a single-system layout of `score` would occupy at its
    /// uncompressed minimum. Sum of per-measure minimum widths + the
    /// first-system part-label reservation.
    ///
    /// Used by `ScoreView` as the `minWidth` floor so the view doesn't
    /// collapse when a parent proposes nil/tiny width (e.g. inside
    /// `ScrollView([.vertical, .horizontal])`).
    public static func naturalContentWidth(
        score: Score, options: ScoreViewOptions,
    ) -> CGFloat {
        let metrics = StaffMetrics(staffSize: options.staffSize)
        let partLabelWidth: CGFloat = 80
        let staves = score.allStaves.map(\.staff)
        guard let firstStaff = staves.first else {
            return partLabelWidth + metrics.sp * 8
        }
        let measureCount = firstStaff.measures.count
        guard measureCount > 0 else {
            return partLabelWidth + metrics.sp * 8
        }
        var total: CGFloat = partLabelWidth
        for i in 0 ..< measureCount {
            let baseHeader = computeHeaderSchedule(
                measureIdx: i,
                staves: staves,
                metrics: metrics,
                synthesizeClefForAllStaves: false,
                synthesizeKeySigForAllStaves: false,
            )
            let w = crossStaffMinimumMeasureWidth(
                staves: staves,
                measureIdx: i,
                metrics: metrics,
                headerSchedule: baseHeader,
                division: score.division,
            )
            total += w
        }
        return total
    }

    /// Shared x-coordinate for every unique tick in a measure, computed
    /// across all voices of all staves.  Mirrors MuseScore's segment
    /// concept: notes at the same tick share one horizontal position
    /// no matter which staff or voice they live in.
    ///
    /// Algorithm (pro-rated gap aggregation):
    /// 1. Collect every unique tick at which ANY voice has a timed
    ///    element starting, plus the measure end (the "fence post"
    ///    after the last tick).
    /// 2. For each pair of consecutive ticks `(t_i, t_{i+1})`, compute
    ///    the minimum horizontal space needed — the MAX across voices
    ///    of the element active at `t_i` scaled to the portion of its
    ///    duration that falls inside `(t_i, t_{i+1})`.  Pro-rating is
    ///    what keeps a long voice-1 element (e.g. a whole note) from
    ///    stealing space from voice 0's uniform quarters, while still
    ///    reserving enough room for its own tick boundaries.
    /// 3. Prefix-sum the gap weights.  Because gap weights are
    ///    non-negative, the resulting x sequence is MONOTONIC — no
    ///    tick ever lands left of an earlier one, even when voices
    ///    have different element counts.
    ///
    /// Returns an empty map when the measure has no timed content.
    static func tickColumns(
        staves: [Staff],
        measureIdx: Int,
        metrics: StaffMetrics,
        headerSchedule: HeaderSchedule,
        width: CGFloat,
        division: Int,
    ) -> [Int: CGFloat] {
        let agg = aggregatedTickWeights(
            staves: staves, measureIdx: measureIdx,
            metrics: metrics, division: division,
        )
        guard !agg.sortedTicks.isEmpty else { return [:] }

        // Trailing slack between the last note's tick and the right
        // barline. Matches `minimumMeasureWidth`'s `rightPadding`;
        // 1 sp also gives flagged 8th / 16th notes room for their
        // flag glyph before the barline.
        let trailingGap = metrics.sp * 1
        // Floor `contentWidth` at `totalWeight`: even when callers
        // hand us a `width` smaller than the cross-staff aggregated
        // minimum, never squeeze gaps below their declared per-segment
        // minimum — that would re-introduce the lyric overlap that
        // `lyricsPairWidth` is supposed to prevent. Excess width
        // beyond `totalWeight` still spreads proportionally, so the
        // measure can stretch but cannot collapse.
        let contentWidth = max(
            agg.totalWeight,
            max(
                metrics.sp * 4,
                width - headerSchedule.contentStartX - trailingGap,
            ),
        )
        let baseX = headerSchedule.contentStartX + metrics.sp

        var tickToX: [Int: CGFloat] = [:]
        var cumulative: CGFloat = 0
        for (i, t) in agg.sortedTicks.enumerated() {
            let fraction = agg.totalWeight > 0
                ? cumulative / agg.totalWeight : 0
            tickToX[t] = baseX + fraction * contentWidth
            cumulative += agg.gapWeights[i]
        }
        return tickToX
    }

    /// Cross-staff aggregated minimum measure width — the smallest
    /// `width` for which `tickColumns` can place every chord/rest
    /// without squeezing any segment below its declared weight.
    ///
    /// Per-staff `minimumMeasureWidth` undercounts when other staves
    /// subdivide a long element: the cross-tick aggregation in
    /// `tickColumns` produces a larger `totalWeight` than any single
    /// staff's sum (e.g. m.32 of test.mscx — Lead's Pa-ra-di-so!
    /// eighths squeezed below 21 sp because V.P.'s 16ths split
    /// Lead's quarter rest into two gaps, each charged the floor
    /// minimum). Using THIS function for layout's per-measure width
    /// keeps the spacing engine and the placement engine in sync.
    static func crossStaffMinimumMeasureWidth(
        staves: [Staff],
        measureIdx: Int,
        metrics: StaffMetrics,
        headerSchedule: HeaderSchedule,
        division: Int,
    ) -> CGFloat {
        let agg = aggregatedTickWeights(
            staves: staves, measureIdx: measureIdx,
            metrics: metrics, division: division,
        )
        // Must match `tickColumns`' trailingGap so the spacing engine
        // and the placement engine size every measure identically.
        let trailingGap = metrics.sp * 1
        let contentWidth = max(metrics.sp * 4, agg.totalWeight)
        // baseX = contentStartX + sp; the rightmost tick lands at
        // baseX + contentWidth; trailing barline / gap follows.
        return headerSchedule.contentStartX + metrics.sp
            + contentWidth + trailingGap
    }

    /// Per-segment aggregation primitive shared by `tickColumns` (uses
    /// it to place chord x-positions) and
    /// `crossStaffMinimumMeasureWidth` (uses it to size the measure
    /// so the placement never has to squeeze). Keeping a single
    /// algorithm avoids the bug where the two diverged and the
    /// minimum width undersized the layout.
    static func aggregatedTickWeights( // swiftlint:disable:this function_body_length
        staves: [Staff],
        measureIdx: Int,
        metrics: StaffMetrics,
        division: Int,
    ) -> (
        sortedTicks: [Int],
        gapWeights: [CGFloat],
        totalWeight: CGFloat,
        measureEnd: Int,
    ) {
        struct TimedElement {
            let startTick: Int
            let endTick: Int
            /// Mutable so a chord line pointing LEFT can widen the gap
            /// that was already recorded for the PREVIOUS element.
            var weight: CGFloat
        }
        // Effective measure duration — used to resolve any `.measure`
        // rest via `NoteDuration.resolved(in:)`. Defensive: no decoder
        // produces `.measure` yet. Derive from the first staff that
        // covers this measure index; time signatures are score-wide.
        let measureDuration: Fraction = {
            guard let staff = staves.first(where: { measureIdx < $0.measures.count }) else {
                return Fraction(numerator: 4, denominator: 4)
            }
            let durations = staff.measures.effectiveMeasureDurations()
            return measureIdx < durations.count
                ? durations[measureIdx]
                : Fraction(numerator: 4, denominator: 4)
        }()
        var voiceElements: [[TimedElement]] = []
        var allTicks: Set<Int> = []
        var measureEnd = 0

        for staff in staves where measureIdx < staff.measures.count {
            for voice in staff.measures[measureIdx].voices {
                var elements: [TimedElement] = []
                var tick = 0
                // Width demand contributed by any `.harmony` not yet
                // attached to a chord/rest at this tick. Folded into
                // the next timed element's weight so the chord segment
                // reserves enough room for the chord symbol.
                var pendingHarmonyWidth: CGFloat = 0
                // Previous notes-bearing chord, for the backward reach of
                // a left-pointing chord line (plop / scoop).
                var previousChord: Chord?
                for (idx, el) in voice.elements.enumerated() {
                    switch el {
                    case let .chord(c) where !c.notes.isEmpty:
                        let nextLyrics = nextChordLyrics(
                            in: voice.elements, after: idx,
                        )
                        // Reserve column width for grace clusters whose
                        // glyphs live inside THIS column's horizontal
                        // span (from THIS tick to the NEXT tick):
                        //   • after-graces of THIS chord appear at the
                        //     right end of this column.
                        //   • before-graces of the NEXT chord appear at
                        //     the left end of the next column — but that
                        //     space is carved from THIS column (the gap
                        //     from THIS tick to the next tick IS this
                        //     column's weight in the proportional spacer).
                        let nextBeforeCount = nextChordBeforeGraceCount(
                            in: voice.elements, after: idx,
                        )
                        let graceBudget = LayoutEngine.graceWidth(sp: metrics.sp)
                            * CGFloat(c.graceNotesAfter.count + nextBeforeCount)
                        // Jazz inflection lines are part of the chord's
                        // shape upstream, so they widen the neighbouring
                        // gaps — a left-pointing scoop/plop reaches back
                        // into the gap already recorded for the previous
                        // element.
                        let inflection = chordLineSpacing(
                            c.chordLines,
                            anchorSteps: spacingSteps(of: c),
                            previousSteps: previousChord.map(spacingSteps(of:)),
                            nextSteps: nextSpacingChord(
                                in: voice.elements, after: idx,
                            ).map(spacingSteps(of:)),
                            metrics: metrics,
                        )
                        if inflection.leftward > 0, let last = elements.indices.last {
                            elements[last].weight = max(
                                elements[last].weight, inflection.leftward,
                            )
                        }
                        let baseWeight = max(
                            durationWidth(c.duration, metrics: metrics) + graceBudget,
                            lyricsPairWidth(
                                currentLyrics: c.lyrics,
                                nextLyrics: nextLyrics,
                                metrics: metrics,
                            ),
                            inflection.rightward,
                        )
                        let w = max(baseWeight, pendingHarmonyWidth)
                        pendingHarmonyWidth = 0
                        let end = tick + c.duration.resolved(in: measureDuration).ticks(division: division)
                        elements.append(TimedElement(
                            startTick: tick, endTick: end, weight: w,
                        ))
                        previousChord = c
                        allTicks.insert(tick)
                        tick = end
                    case let .chord(r):
                        // Empty chord = rest.
                        let baseWeight = durationWidth(
                            r.duration, metrics: metrics,
                        )
                        let w = max(baseWeight, pendingHarmonyWidth)
                        pendingHarmonyWidth = 0
                        let end = tick + r.duration.resolved(in: measureDuration).ticks(division: division)
                        elements.append(TimedElement(
                            startTick: tick, endTick: end, weight: w,
                        ))
                        allTicks.insert(tick)
                        tick = end
                    case let .harmony(harmony) where harmony.visible:
                        // Pre-measure so the next chord/rest segment
                        // carries demand to host the symbol without
                        // colliding with the next chord. + 0.5 sp gap.
                        let runs = HarmonyRendering.runs(
                            for: harmony, metrics: metrics,
                        )
                        pendingHarmonyWidth = max(
                            pendingHarmonyWidth,
                            CGFloat(HarmonyRendering.width(of: runs))
                                + metrics.sp * 0.5,
                        )
                    case let .breath(b):
                        // EVERY breath reserves a fixed visual slot
                        // for its glyph (regardless of pause). Without
                        // this, two consecutive breath marks in the
                        // same gap (e.g. one between chords, one at
                        // the end of a measure) collapse on top of
                        // each other because no spacing element is
                        // alive across them. The reservation is given
                        // in ticks so the existing tick→X mapping
                        // produces ~one quarter's worth of breathing
                        // room (≈ 2 sp at default spacing).
                        //
                        // Breaths with `pause > 0` (caesuras with
                        // their pause-seconds) additionally advance
                        // the tick cursor by the MIDI tick budget so
                        // subsequent chords sit at their post-pause
                        // ticks and `tickColumns` produces matching
                        // keys for the placement walker.
                        //
                        // TODO: multi-tempo scores — sample the tempo
                        // timeline at the breath's tick instead of
                        // hard-coding 2.0 bps (120 BPM). Mirrors the
                        // same TODO in `LayoutEngine+Placement.swift`.
                        let breathGlyphReservationTicks = 120
                        var extraTicks = breathGlyphReservationTicks
                        if b.pause > 0 {
                            let bps = 2.0
                            extraTicks += Int(
                                (b.pause * bps * Double(division))
                                    .rounded(),
                            )
                        }
                        tick += extraTicks
                    default:
                        break
                    }
                }
                if !elements.isEmpty {
                    voiceElements.append(elements)
                    measureEnd = max(measureEnd, tick)
                }
            }
        }

        guard !allTicks.isEmpty else {
            return ([], [], 0, 0)
        }
        let sortedTicks = allTicks.sorted()

        var gapWeights: [CGFloat] = []
        gapWeights.reserveCapacity(sortedTicks.count)
        for i in 0 ..< sortedTicks.count {
            let tStart = sortedTicks[i]
            let tEnd = i + 1 < sortedTicks.count
                ? sortedTicks[i + 1]
                : measureEnd
            let gapTicks = tEnd - tStart
            guard gapTicks > 0 else {
                gapWeights.append(0)
                continue
            }
            var maxGap: CGFloat = 0
            for elements in voiceElements {
                for el in elements where el.startTick <= tStart
                    && el.endTick > tStart
                {
                    let duration = el.endTick - el.startTick
                    guard duration > 0 else { break }
                    let share = el.weight
                        * CGFloat(gapTicks) / CGFloat(duration)
                    maxGap = max(maxGap, share)
                    break
                }
            }
            gapWeights.append(maxGap)
        }

        let totalWeight = gapWeights.reduce(0, +)
        return (sortedTicks, gapWeights, totalWeight, measureEnd)
    }

    /// Extra width the FIRST measure of a system needs beyond its
    /// natural `minimumMeasureWidth` to fit the clef + key signature
    /// that engraving redraws at every system head.
    ///
    /// `minimumMeasureWidth` only counts elements physically present
    /// inside the measure's `<voice>`. When wrapping promotes an
    /// interior measure to a system head, `computeHeaderSchedule`
    /// synthesises a clef + key signature at the line start — eating
    /// into the chord content area without anyone having reserved the
    /// space. The result is squeezed lyrics that overlap each other,
    /// despite the same measure spacing fine in horizontal mode.
    /// We compute the synth overhead here and add it to the first
    /// measure's width during system packing.
    static func synthHeaderOverhead(
        staves: [Staff],
        measureIdx: Int,
        activeKeys: [Int],
        metrics: StaffMetrics,
    ) -> CGFloat {
        var clefBoost: CGFloat = 0
        var keyBoost: CGFloat = 0
        for (staffIdx, staff) in staves.enumerated() {
            guard measureIdx < staff.measures.count else { continue }
            let measure = staff.measures[measureIdx]
            var hasExplicitClef = false
            var explicitKeyWidth: CGFloat = 0
            scan: for el in measure.voices.first?.elements ?? [] {
                switch el {
                case .clef:
                    hasExplicitClef = true
                case let .keySignature(k):
                    explicitKeyWidth = max(
                        explicitKeyWidth,
                        metrics.sp * (CGFloat(abs(k.concertKey)) + 1),
                    )
                case .chord:
                    break scan
                default:
                    continue
                }
            }
            if !hasExplicitClef {
                clefBoost = max(clefBoost, metrics.sp * 2)
            }
            let activeKey = staffIdx < activeKeys.count
                ? activeKeys[staffIdx] : 0
            if activeKey != 0 {
                let synthKeyW = metrics.sp
                    * (CGFloat(abs(activeKey)) + 1.5)
                keyBoost = max(
                    keyBoost,
                    max(0, synthKeyW - explicitKeyWidth),
                )
            }
        }
        return clefBoost + keyBoost
    }

    static func minimumMeasureWidth(
        measure: Measure,
        metrics: StaffMetrics,
    ) -> CGFloat {
        // Edge padding inside the barlines. `rightPadding` must
        // be wide enough that a flagged 8th / 16th at the end of
        // the measure doesn't crash its flag glyph (extends ~1.1
        // sp past the stem) into the right barline. 1 sp = ~3.4
        // pt is the minimum that consistently clears the flag.
        let leftPadding = metrics.sp * 1.0
        let rightPadding = metrics.sp * 1.0
        var maxVoiceWidth: CGFloat = 0
        for voice in measure.voices {
            var w: CGFloat = 0
            for (idx, el) in voice.elements.enumerated() {
                switch el {
                // Header element widths sized against MuseScore's
                // engraving defaults. Treble clef glyph ≈ 2.2 sp
                // wide, but `Sid::clefBarlineDistance` overlaps the
                // glyph with the barline by ~0.5 sp, netting ~1.7 sp.
                case .clef:
                    w += metrics.sp * 1.7
                // Key sig: `|k|` accidentals × ~1 sp each, plus
                // `keysigLeftMargin` (0.5 sp). `+ 0.5` instead of
                // the previous `+ 1` more closely matches MuseScore.
                case let .keySignature(k):
                    w += metrics.sp
                        * (CGFloat(abs(k.concertKey)) + 0.5)
                // Time sig: 1.7 sp digit + 0.5 sp barline distance.
                case .timeSignature:
                    w += metrics.sp * 2.2
                case .barLine:
                    w += metrics.sp
                case let .chord(c) where !c.notes.isEmpty:
                    let tickW = durationWidth(c.duration, metrics: metrics)
                    let nextLyrics = nextChordLyrics(
                        in: voice.elements, after: idx,
                    )
                    let lyricW = lyricsPairWidth(
                        currentLyrics: c.lyrics,
                        nextLyrics: nextLyrics,
                        metrics: metrics,
                    )
                    w += max(tickW, lyricW)
                case let .chord(r):
                    // Empty chord = rest.
                    w += durationWidth(r.duration, metrics: metrics)
                case .dynamic, .fermata, .breath,
                     .measureRepeat, .spanner,
                     .locationShift, .harmony:
                    break
                }
            }
            maxVoiceWidth = max(maxVoiceWidth, w)
        }
        return leftPadding + maxVoiceWidth + rightPadding
    }

    /// Anchor-to-anchor room a chord's jazz inflection lines demand from
    /// their neighbours.
    ///
    /// A `ChordLine` is part of the chord's shape upstream — it is added
    /// by `ChordLayout::fillShape`'s `item->el()` loop
    /// (`rendering/score/chordlayout.cpp`), so `HorizontalSpacing` has
    /// to clear it. But upstream only *sometimes* charges for it:
    ///
    ///  * `doComputeKerningType` returns `KerningType::KERNING` for a
    ///    chord line against anything but a barline. Plain `KERNING`
    ///    hits the `default: break` arm of `minHorizontalDistance`'s
    ///    switch, contributing **nothing** — the line is free to tuck in
    ///    beside the neighbour.
    ///  * That only changes when the two shape rectangles **vertically
    ///    intersect**, in which case the earlier branch applies the full
    ///    `r1.right() − r2.left() + padding` clearance.
    ///  * Against a barline the kerning type is `ALLOW_COLLISION`, so a
    ///    line on the last chord of a measure costs nothing at all.
    ///
    /// So the reservation is conditional on vertical overlap with the
    /// neighbouring chord, and absent at a barline. `neighbourSteps` is
    /// nil when there is no neighbouring chord on that side.
    ///
    /// Magnitude, with MuseScore's defaults
    /// (`paddingTable[CHORDLINE][*] = 0.35 sp`, Bravura notehead
    /// half-width 0.59 sp):
    ///
    ///     0.59 + 0.33 (horOffset) + 1.2 (reach) + 0.08 (half stroke)
    ///          + 0.59 + 0.35 (padding)  =  3.14 sp
    ///
    /// We land on the same figure via the shared `noteheadHalfExtent`
    /// (0.7 sp) plus `minNoteDistance`-equivalent slack.
    ///
    /// Measured at full size: this pass has no access to
    /// `ScoreViewOptions.smallNoteMag`, and over-reserving for a
    /// cue-sized chord only ever leaves a little extra air.
    static func chordLineSpacing(
        _ lines: [ChordLine],
        anchorSteps: [Int],
        previousSteps: [Int]?,
        nextSteps: [Int]?,
        metrics: StaffMetrics,
    ) -> (leftward: CGFloat, rightward: CGFloat) {
        guard !lines.isEmpty else { return (0, 0) }
        let halfHead = noteheadHalfExtent(sp: metrics.sp)
        let reach = halfHead
            + ChordLineGeometry.horizontalOffsetSp * metrics.sp
            + ChordLineGeometry.horizontalLengthSp * metrics.sp
            + ChordLineGeometry.thickness(sp: metrics.sp)
            + halfHead
        var leftward: CGFloat = 0
        var rightward: CGFloat = 0
        for line in lines where line.visible {
            let neighbour = line.isToTheLeft ? previousSteps : nextSteps
            // No neighbouring chord on that side means the line faces a
            // barline, which upstream lets it collide with outright.
            guard let neighbour, !neighbour.isEmpty,
                  chordLineOverlapsNeighbour(
                      line, anchorSteps: anchorSteps, neighbourSteps: neighbour,
                  )
            else { continue }
            if line.isToTheLeft {
                leftward = max(leftward, reach)
            } else {
                rightward = max(rightward, reach)
            }
        }
        return (leftward, rightward)
    }

    /// Whether a chord line's vertical band intersects the neighbouring
    /// chord's noteheads — the `intersects(ay1, ay2, by1, by2, …)` test
    /// in `HorizontalSpacing::minHorizontalDistance`.
    ///
    /// Bands are in staff spaces relative to the anchor note's centre,
    /// y growing downward. Only noteheads are considered: the neighbour's
    /// stem is either on its far side (stem up, drawn at the notehead's
    /// right) or exactly at its notehead's left edge (stem down), so the
    /// notehead is always the binding rectangle.
    static func chordLineOverlapsNeighbour(
        _ line: ChordLine, anchorSteps: [Int], neighbourSteps: [Int],
    ) -> Bool {
        // The anchor is the chord's up-note (largest step = highest).
        guard let anchor = anchorSteps.max() else { return false }
        let offset = ChordLineGeometry.verticalOffsetSp
        let length = ChordLineGeometry.verticalLengthSp
        let lineTop = line.isBelow ? offset : -(offset + length)
        let lineBottom = line.isBelow ? offset + length : -offset

        // Staff steps grow upward; screen y grows downward, and one step
        // is half a staff space.
        let deltas = neighbourSteps.map { -0.5 * CGFloat($0 - anchor) }
        guard let top = deltas.min(), let bottom = deltas.max() else {
            return false
        }
        return lineBottom > top - 0.5 && lineTop < bottom + 0.5
    }

    /// Staff steps of a chord's notes. The clef cancels out because only
    /// differences between chords are ever compared, so a fixed treble
    /// reference is safe here.
    static func spacingSteps(of chord: Chord) -> [Int] {
        chord.notes.map {
            PitchStaffPosition.step(
                midiPitch: $0.pitch, tpc: $0.tpc, clef: .treble,
            ).step
        }
    }

    /// The next notes-bearing chord in a voice, or nil at a barline.
    static func nextSpacingChord(
        in elements: [VoiceElement], after index: Int,
    ) -> Chord? {
        for element in elements[(index + 1)...] {
            if case let .chord(chord) = element, !chord.notes.isEmpty {
                return chord
            }
        }
        return nil
    }

    static func durationWidth(
        _ dur: NoteDuration, metrics: StaffMetrics,
    ) -> CGFloat {
        // Linear in quarter-equivalent length, with a minimum floor so
        // very short notes (32nd, 64th) don't collapse to zero space.
        let quarters: Double
        switch dur {
        case .whole: quarters = 4
        case .half: quarters = 2
        case .quarter: quarters = 1
        case .eighth: quarters = 0.5
        case .sixteenth: quarters = 0.25
        case .thirtySecond: quarters = 0.125
        case .sixtyFourth: quarters = 0.0625
        case .oneTwentyEighth: quarters = 1.0 / 32
        case .twoFiftySixth: quarters = 1.0 / 64
        case .measure:
            // Renders as a whole-rest glyph; allocate whole-rest width.
            quarters = 4
        case let .fraction(f):
            quarters = Double(f.numerator) / Double(f.denominator) * 4
        }
        let baseWidth = metrics.spacePerQuarter * CGFloat(quarters)
        // Per-note clearance floor. MuseScore's
        // `Sid::shortestNoteDistance` is 1.5 sp baseline. Going
        // higher (e.g. 1.8 sp) for flagged notes would protect
        // against flag/beam collision, but it also pushes
        // 4-measure systems with rapid 16ths over the available
        // width — breaking the systems-per-line balance the
        // explicit LayoutBreaks expect. We accept the tighter
        // 16th-note spacing in exchange.
        let floor = metrics.sp * 1.5
        return max(baseWidth, floor)
    }

    /// Minimum tick-to-tick (chord-anchor to next-anchor) distance so
    /// the current chord's lyric and the next voice element's lyric
    /// don't overlap, with extra room for a connecting dash when the
    /// current syllable is BEGIN/MIDDLE.
    ///
    /// Mirrors MuseScore's `HorizontalSpacing::computeLyricsPadding`
    /// (`engraving/rendering/score/horizontalspacing.cpp:1586`) plus
    /// the default style values:
    ///
    ///   * `lyricsDashMinLength`  = 0.4 sp
    ///   * `lyricsDashPad`        = 0.05 sp (×2)
    ///   * `lyricsDashForce`      = true
    ///   * `lyricsMinDistance`    = 0.25 sp
    ///
    /// Lyrics are rendered centered on the chord anchor, so the center
    /// distance must clear `halfL1 + interSyllable + halfL2`. The
    /// previous implementation used only the CURRENT chord's lyric
    /// width and assumed symmetry — fine for uniform Latin runs but
    /// wrong when a wide syllable follows a narrow one (CJK / ASCII
    /// mix) or when font measurement under-reports advance.
    ///
    /// Returns 0 when the current chord has no lyric — duration spacing
    /// still applies via `durationWidth`.
    static func lyricsPairWidth(
        currentLyrics: [Lyric],
        nextLyrics: [Lyric],
        metrics: StaffMetrics,
    ) -> CGFloat {
        let curWidth = chordLyricMaxWidth(currentLyrics, metrics: metrics)
        guard curWidth > 0 else { return 0 }
        let nextWidth = chordLyricMaxWidth(nextLyrics, metrics: metrics)
        let dashForce = currentLyrics.contains { lyric in
            !lyric.text.isEmpty
                && (lyric.syllabic == .begin || lyric.syllabic == .middle)
        }
        // Dash spacing only applies when the next chord actually has a
        // syllable to connect to; otherwise we just need the regular
        // min-distance buffer.
        let inter: CGFloat = (dashForce && nextWidth > 0)
            ? metrics.sp * 0.5
            : metrics.sp * 0.25
        return curWidth / 2 + inter + nextWidth / 2
    }

    /// Widest rendered lyric in a chord (verse-aware: takes the max
    /// across verses). Returns 0 when no syllable has text.
    static func chordLyricMaxWidth(
        _ lyrics: [Lyric], metrics: StaffMetrics,
    ) -> CGFloat {
        var widest: CGFloat = 0
        for lyric in lyrics where !lyric.text.isEmpty {
            widest = max(
                widest,
                lyricsTextWidth(lyric.text, sp: metrics.sp),
            )
        }
        return widest
    }

    /// First chord's lyrics that follow the element at `startIndex` in
    /// `elements`, looking past clefs / key sigs / barlines / etc. that
    /// don't carry a tick. Empty when no further chord exists.
    static func nextChordLyrics(
        in elements: [VoiceElement], after startIndex: Int,
    ) -> [Lyric] {
        guard startIndex + 1 < elements.count else { return [] }
        for j in (startIndex + 1) ..< elements.count {
            switch elements[j] {
            case let .chord(nc) where !nc.notes.isEmpty:
                return nc.lyrics
            case .chord:
                // Empty chord = rest.
                return []
            default:
                continue
            }
        }
        return []
    }

    /// Number of before-graces on the next note-chord after `startIndex`.
    /// Used to widen THIS chord's column weight so the graces of the NEXT
    /// chord don't collide with THIS chord's notehead: the gap from THIS
    /// tick to the NEXT tick is THIS column's responsibility in the
    /// proportional spacer.
    static func nextChordBeforeGraceCount(
        in elements: [VoiceElement], after startIndex: Int,
    ) -> Int {
        guard startIndex + 1 < elements.count else { return 0 }
        for j in (startIndex + 1) ..< elements.count {
            switch elements[j] {
            case let .chord(nc) where !nc.notes.isEmpty:
                return nc.graceNotesBefore.count
            case .chord:
                // Rest — no graces.
                return 0
            default:
                continue
            }
        }
        return 0
    }
}
