// swiftlint:disable file_length
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    /// A chord or rest's address in the score — the four fields `NoteID`
    /// and `RestID` share. Both ends of a slur are `ChordRest`s in
    /// MuseScore's model, and a rest is a note-less `Chord` in ours, so one
    /// key has to reach either.
    struct ChordRestRef: Hashable {
        let staff: StaffAddress
        let measureIndex: Int
        let voiceIndex: Int
        let elementIndex: Int

        init(
            staff: StaffAddress,
            measureIndex: Int,
            voiceIndex: Int,
            elementIndex: Int,
        ) {
            self.staff = staff
            self.measureIndex = measureIndex
            self.voiceIndex = voiceIndex
            self.elementIndex = elementIndex
        }

        init(noteID: NoteID) {
            self.init(
                staff: noteID.staff,
                measureIndex: noteID.measureIndex,
                voiceIndex: noteID.voiceIndex,
                elementIndex: noteID.elementIndex,
            )
        }

        init(restID: RestID) {
            self.init(
                staff: restID.staff,
                measureIndex: restID.measureIndex,
                voiceIndex: restID.voiceIndex,
                elementIndex: restID.elementIndex,
            )
        }
    }

    /// One chord-anchored slur's endpoints as score ADDRESSES, before
    /// layout coordinates are known. Mirrors `GuitarBendPairing`: the
    /// side the arc takes is deliberately absent, because it can depend on
    /// the start chord's stem direction, which only exists once the score
    /// is laid out.
    struct SlurPairing: Equatable {
        let start: ChordRestRef
        let end: ChordRestRef
        /// Authored `<placement>` override, or `nil` to compute the side.
        let placement: Spanner.Placement?
        /// `true` when any measure the slur spans carries more than one
        /// voice with content — MuseScore's `measure->hasVoices(staffIdx…)`.
        let multiVoice: Bool
    }

    /// Walk every staff / measure / voice / element and pair each
    /// chord-anchored `.slur` spanner with the chord or rest its
    /// `<next><location>` points at.
    ///
    /// Hidden slurs (`<visible>0`) are skipped here, exactly as
    /// `collectSpanners` skips a hidden voice-level spanner: no glyph, no
    /// reserved space, playback untouched.
    ///
    /// **Cross-voice slurs are re-homed, not detected.** MuseScore's
    /// `<location>` can carry a `<voices>` hop
    /// (`slur_ms3_exchangevoices.mscx:224-229`) that the model does not
    /// hold, so this walk looks the end up in the START voice and draws the
    /// arc at whatever sits there. That is the same thing the encoder does
    /// with the same missing field (`Chord.pendingSlurEnds(at:)`), so the
    /// two stay consistent; modelling `<voices>` is the fix for both.
    static func collectSlurs(score: Score) -> [SlurPairing] {
        var out: [SlurPairing] = []
        for (address, staff) in score.allStaves {
            let durations = staff.measures.effectiveMeasureDurations()
            for (measureIndex, measure) in staff.measures.enumerated() {
                let measureDuration = durations.indices.contains(measureIndex)
                    ? durations[measureIndex]
                    : Fraction(numerator: 4, denominator: 4)
                for (voiceIndex, voice) in measure.voices.enumerated() {
                    var tick = 0
                    for (elementIndex, element) in voice.elements.enumerated() {
                        switch element {
                        case let .chord(chord):
                            let start = ChordRestRef(
                                staff: address,
                                measureIndex: measureIndex,
                                voiceIndex: voiceIndex,
                                elementIndex: elementIndex,
                            )
                            out.append(contentsOf: pairings(
                                for: chord, start: start, staff: staff,
                                startTick: tick, division: score.division,
                            ))
                            tick += chord.duration
                                .resolved(in: measureDuration)
                                .ticks(division: score.division)
                        case let .locationShift(delta):
                            // Same cursor rule `collectSpanners` and
                            // `placeMeasureElements` walk with: a voice
                            // starting part-way through the measure has to
                            // advance here too, or every slur in it anchors
                            // at the wrong tick.
                            tick += delta.ticks(division: score.division)
                        default:
                            break
                        }
                    }
                }
            }
        }
        return out
    }

    /// One chord's slur spanners → their pairings, dropping the ones whose
    /// end cannot be resolved.
    private static func pairings(
        for chord: Chord,
        start: ChordRestRef,
        staff: Staff,
        startTick: Int,
        division: Int,
    ) -> [SlurPairing] {
        chord.spanners.compactMap { spanner in
            guard spanner.kind == .slur, spanner.visible else { return nil }
            guard let end = slurEnd(
                spanner: spanner, staff: staff,
                startMeasureIndex: start.measureIndex,
                startTick: startTick,
                voiceIndex: start.voiceIndex,
                division: division,
            ) else { return nil }
            let endRef = ChordRestRef(
                staff: start.staff,
                measureIndex: end.measureIndex,
                voiceIndex: start.voiceIndex,
                elementIndex: end.elementIndex,
            )
            // An end that resolves back onto the start chord is a
            // zero-length arc — drop it rather than draw a dot.
            guard endRef != start else { return nil }
            return SlurPairing(
                start: start,
                end: endRef,
                placement: spanner.placement,
                multiVoice: hasVoices(
                    staff: staff,
                    from: start.measureIndex,
                    to: end.measureIndex,
                ),
            )
        }
    }

    /// The chord/rest a slur's `<next><location>` lands on, as (measure
    /// index, element index in the start voice), or `nil` when nothing
    /// sits there.
    private static func slurEnd(
        spanner: Spanner,
        staff: Staff,
        startMeasureIndex: Int,
        startTick: Int,
        voiceIndex: Int,
        division: Int,
    ) -> (measureIndex: Int, elementIndex: Int)? {
        guard let anchor = slurEndAnchor(
            startMeasureIndex: startMeasureIndex,
            startTick: startTick,
            nextMeasuresOffset: spanner.nextMeasuresOffset,
            nextFractionsOffset: spanner.nextFractionsOffset,
            measures: staff.measures,
            division: division,
        ) else { return nil }
        let measure = staff.measures[anchor.measureIndex]
        guard measure.voices.indices.contains(voiceIndex) else { return nil }
        let durations = staff.measures.effectiveMeasureDurations()
        let measureDuration = durations.indices.contains(anchor.measureIndex)
            ? durations[anchor.measureIndex]
            : Fraction(numerator: 4, denominator: 4)
        guard let elementIndex = chordRestIndex(
            in: measure.voices[voiceIndex],
            atTick: anchor.tick,
            measureDuration: measureDuration,
            division: division,
        ) else { return nil }
        return (anchor.measureIndex, elementIndex)
    }

    /// Resolve a chord-anchored slur's end to a (measure index, in-measure
    /// tick) pair, normalising a result that runs past — or before — the
    /// target measure's bar lines.
    ///
    /// The `<location>` arithmetic is the same one `endAnchor` performs for
    /// a voice-level spanner: `<measures>N` advances N measure indices,
    /// `<fractions>F` shifts the position within the resulting measure.
    /// What is deliberately NOT reused is `endAnchor`'s right-edge
    /// sentinel. A hairpin that stops on a bar line must be drawn TO that
    /// bar line, so `endAnchor` collapses such a result back onto the
    /// previous measure with `endTick == 0`. A slur's end is a CHORD, and
    /// the chord on that bar line is the downbeat of the FOLLOWING measure:
    /// `slur_ms3_exchangevoices.mscx:200-216` writes
    /// `<measures>1</measures><fractions>-1/2</fractions>` off the half note
    /// at 1/2 of measure 2, and its `<prev>` partner (`:250-264`) sits on
    /// the downbeat of measure 3. Through `endAnchor` that resolves to
    /// measure 2 instead, re-homing the arc onto the slur's own start bar.
    ///
    /// Returns `nil` when the offset lands outside the score — the "end
    /// past the last measure" case, dropped in silence like `resolveTies`'
    /// unmatched ties.
    static func slurEndAnchor(
        startMeasureIndex: Int,
        startTick: Int,
        nextMeasuresOffset: Int,
        nextFractionsOffset: Fraction?,
        measures: [Measure],
        division: Int,
    ) -> (measureIndex: Int, tick: Int)? {
        let durations = measures.effectiveMeasureDurations()
        func width(_ index: Int) -> Int {
            let duration = durations.indices.contains(index)
                ? durations[index]
                : Fraction(numerator: 4, denominator: 4)
            return measureTickCount(
                measures[index], division: division,
                measureDuration: duration,
            )
        }
        var index = startMeasureIndex + max(0, nextMeasuresOffset)
        var tick = startTick
            + (nextFractionsOffset?.ticks(division: division) ?? 0)
        // Carry forward across bar lines. The `> 0` guard keeps an empty
        // measure (width 0) from spinning here forever.
        while measures.indices.contains(index) {
            let measureWidth = width(index)
            guard measureWidth > 0, tick >= measureWidth else { break }
            tick -= measureWidth
            index += 1
        }
        // Carry back: a negative `<fractions>` on top of `<measures>` (the
        // MS3 barline-crossing shape) rolls into the previous measure.
        while tick < 0, index > 0 {
            index -= 1
            guard measures.indices.contains(index) else { return nil }
            tick += width(index)
        }
        guard measures.indices.contains(index), tick >= 0 else { return nil }
        return (index, tick)
    }

    /// Index of the chord/rest starting exactly at `tick` in `voice`, or
    /// `nil` when the offset lands between notes (or past the end).
    /// Walks the same cursor `placeMeasureElements` does, `.locationShift`
    /// included.
    static func chordRestIndex(
        in voice: Voice,
        atTick tick: Int,
        measureDuration: Fraction,
        division: Int,
    ) -> Int? {
        var cursor = 0
        for (index, element) in voice.elements.enumerated() {
            if cursor > tick { return nil }
            switch element {
            case let .chord(chord):
                if cursor == tick { return index }
                cursor += chord.duration
                    .resolved(in: measureDuration)
                    .ticks(division: division)
            case let .locationShift(delta):
                cursor += delta.ticks(division: division)
            default:
                break
            }
        }
        return nil
    }

    /// MuseScore's `measure->hasVoices(staffIdx, …)` walked over every
    /// measure the slur spans (`slurtielayout.cpp:2610-2618`): more than
    /// one voice actually carrying content.
    private static func hasVoices(staff: Staff, from: Int, to: Int) -> Bool {
        let range = min(from, to) ... max(from, to)
        for index in range where staff.measures.indices.contains(index) {
            let filled = staff.measures[index].voices
                .filter { !$0.elements.isEmpty }
            if filled.count > 1 { return true }
        }
        return false
    }

    /// Which side of the staff a slur arcs to. Ports
    /// `SlurTieLayout::computeUp`
    /// (`rendering/score/slurtielayout.cpp:2566-2636`), keeping the
    /// branches this pipeline has data for, in the C++'s own precedence:
    ///
    /// 0. **Authored side.** C++ reads it off `slur->slurDirection()`
    ///    (`:2568-2574`) and returns before computing anything. Ours is the
    ///    decoded `<placement>` — `<up>`, the tag MuseScore actually writes
    ///    for a hand-flipped slur, is not modeled (see
    ///    `SlurDecodeTests.unknownSlurChildrenWarn`).
    /// 1. **Multi-voice parity**, when any measure the slur spans carries
    ///    more than one voice (`:2609-2625`): "slurs go on the stem side" —
    ///    `if (chordRest1->voice() > 0 || chordRest2->voice() > 0)
    ///    slur->setUp(false); else slur->setUp(true);`. Voice 0 at BOTH
    ///    ends → above; any other voice at either end → below. This runs
    ///    last in the C++ and overwrites the stem-opposite result assigned
    ///    at `:2606`, which is why it is checked first here.
    ///
    ///    Note the parity is the OPPOSITE of `GuitarBendLayout::computeUp`'s
    ///    `setUp(track() % 2)` — voice 0 arcs UP for a slur and DOWN for a
    ///    bend — so this is transcribed rather than shared with `bendIsUp`.
    /// 2. **Stem-opposite**, the plain AUTO answer:
    ///    `slur->setUp(!(chordRest1->up()))` (`:2606`). A stem-UP start
    ///    chord takes the slur below, a stem-DOWN one above.
    /// 3. **No stem to read** — a slur starting on a rest → `true`, which is
    ///    the C++'s own fallback when either end is not a `ChordRest`
    ///    (`:2583-2586`).
    ///
    /// NOT ported: the cross-staff-beam branch (`:2600-2604`) and the two
    /// `isDirectionMixture` branches (`:2626-2632`), which need stem
    /// directions across the whole span plus beam state. The
    /// `ChordLayout::computeUp` re-run at `:2589-2598` has no analogue
    /// either — it is a HACK for an end chord in an unlaid-out system, and
    /// this pass resolves after layout, so the stem is already final.
    static func slurIsAbove(
        pairing: SlurPairing, startStem: StemDirection?,
    ) -> Bool {
        if let placement = pairing.placement {
            return placement == .above
        }
        if pairing.multiVoice {
            return pairing.start.voiceIndex == 0
                && pairing.end.voiceIndex == 0
        }
        guard let startStem else { return true }
        return startStem == .down
    }

    /// One laid-out chord/rest's slur anchor material, in ABSOLUTE
    /// coordinates (system + measure + element origin), the frame
    /// `TiePair` is expressed in.
    private struct SlurAnchor {
        /// Notehead origins with their staff steps, `mirrorDx` already
        /// applied. Empty for a rest.
        var heads: [(step: Int, point: CGPoint)] = []
        /// Rest glyph origin. `nil` for a chord.
        var rest: CGPoint?
        /// Stem direction of the chord, `nil` for a rest.
        var stem: StemDirection?
        /// Staff index within the system, matched the way `resolveTies`
        /// matches it so it stays stable across a system break.
        var staffIndex = 0
    }

    /// Resolve `collectSlurs`' address pairs against the laid-out
    /// `document` into `TiePair`s ready for `attachArcs`. One walk over
    /// every system builds the anchor map — the same shape
    /// `resolveGuitarBends` uses — then each pairing looks its two ends up.
    /// Pairs with an end the map does not cover are dropped silently, the
    /// v1 policy every other post-pass applies.
    static func resolveSlurs(
        for document: LayoutDocument,
        score: Score,
    ) -> [TiePair] {
        let pairings = collectSlurs(score: score)
        guard !pairings.isEmpty else { return [] }

        var needed: Set<ChordRestRef> = []
        for pairing in pairings {
            needed.insert(pairing.start)
            needed.insert(pairing.end)
        }
        let anchors = slurAnchors(in: document, needed: needed)

        return pairings.compactMap { pairing in
            guard let from = anchors[pairing.start],
                  let to = anchors[pairing.end]
            else { return nil }
            let above = slurIsAbove(pairing: pairing, startStem: from.stem)
            guard let fromOrigin = endpoint(of: from, above: above),
                  let toOrigin = endpoint(of: to, above: above)
            else { return nil }
            return TiePair(
                staff: from.staffIndex,
                fromOrigin: fromOrigin,
                toOrigin: toOrigin,
                above: above,
            )
        }
    }

    /// Absolute anchor material for every chord/rest in `needed`.
    private static func slurAnchors(
        in document: LayoutDocument,
        needed: Set<ChordRestRef>,
    ) -> [ChordRestRef: SlurAnchor] {
        var out: [ChordRestRef: SlurAnchor] = [:]
        let sp = document.metrics.sp
        // REFERENCE frame, not drawn extent — same reasoning as
        // `resolveTies`: `step == 0` sits half the FIVE-LINE staff height
        // below every staff's origin, whatever its line count.
        let staffMidOffset = document.metrics.staffHeight / 2
        for system in document.systems {
            let staffMidYsLocal = system.staffOrigins.map {
                $0.y + staffMidOffset
            }
            for measure in system.measures {
                for element in measure.elements {
                    let origin = CGPoint(
                        x: system.origin.x + measure.origin.x,
                        y: system.origin.y + measure.origin.y,
                    )
                    guard let entry = anchor(
                        for: element, measureOrigin: origin,
                        systemOriginY: system.origin.y,
                        staffMidYsLocal: staffMidYsLocal, sp: sp,
                        needed: needed,
                    ) else { continue }
                    out[entry.ref] = entry.anchor
                }
            }
        }
        return out
    }

    /// One laid-out element's anchor entry, or `nil` when it is neither a
    /// wanted chord nor a wanted rest.
    private static func anchor( // swiftlint:disable:this function_parameter_count
        for element: LayoutElement,
        measureOrigin: CGPoint,
        systemOriginY: CGFloat,
        staffMidYsLocal: [CGFloat],
        sp: CGFloat,
        needed: Set<ChordRestRef>,
    ) -> (ref: ChordRestRef, anchor: SlurAnchor)? {
        switch element {
        case let .chord(notes, _, stem, _, _, _, _, _, _, _, _):
            guard let first = notes.first else { return nil }
            let ref = ChordRestRef(noteID: first.noteID)
            guard needed.contains(ref) else { return nil }
            var entry = SlurAnchor()
            entry.stem = stem
            entry.heads = notes.map { note in
                // Anchor on the VISUAL notehead, `resolveTies`'
                // convention: a mirrored note (in a second) has to be
                // reached at the side its head was pushed to.
                (
                    step: note.step,
                    point: CGPoint(
                        x: measureOrigin.x + note.origin.x
                            + note.mirrorDx(stem: stem, sp: sp),
                        y: measureOrigin.y + note.origin.y,
                    ),
                )
            }
            let head = entry.heads[0]
            entry.staffIndex = nearestStaffIndex(
                toMidYLocal: (head.point.y - systemOriginY)
                    + CGFloat(head.step) * sp / 2,
                in: staffMidYsLocal,
            )
            return (ref, entry)
        case let .rest(_, restOrigin, _, restID, _):
            let ref = ChordRestRef(restID: restID)
            guard needed.contains(ref) else { return nil }
            var entry = SlurAnchor()
            let point = CGPoint(
                x: measureOrigin.x + restOrigin.x,
                y: measureOrigin.y + restOrigin.y,
            )
            entry.rest = point
            // A rest carries no step, so its own y is the best midline
            // estimate available — rests are drawn inside the staff.
            entry.staffIndex = nearestStaffIndex(
                toMidYLocal: point.y - systemOriginY, in: staffMidYsLocal,
            )
            return (ref, entry)
        default:
            return nil
        }
    }

    /// The arc endpoint on `anchor`: the outermost notehead on the arc's
    /// own side — topmost (largest step) for an arc above, bottommost for
    /// one below — or the rest glyph's origin when the slur hangs off a
    /// rest. Raw origins; the head clearance lives in `TieArcGeometry`.
    private static func endpoint(
        of anchor: SlurAnchor, above: Bool,
    ) -> CGPoint? {
        if anchor.heads.isEmpty { return anchor.rest }
        let chosen = above
            ? anchor.heads.max { $0.step < $1.step }
            : anchor.heads.min { $0.step < $1.step }
        return chosen?.point
    }
}
