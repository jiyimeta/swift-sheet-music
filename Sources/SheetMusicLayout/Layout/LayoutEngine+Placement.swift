// swiftlint:disable file_length
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// A melisma that extends INTO a measure from an earlier measure.
/// The anchor measure (where the `<Lyrics>` element lives) is
/// handled inside `emitMelismaLine`; instances of this type describe
/// the left-hand continuation rule drawn on the following measures.
struct MelismaContinuation: Equatable {
    let voiceIndex: Int
    let verseIndex: Int
    /// Tick (within this measure's voice time) where the line
    /// terminates. Ignored when `continuesPastMeasure` is true.
    let endTick: Int
    /// The melisma spans all of this measure and keeps going into
    /// the next one — the rule should run through to the trailing
    /// barline (and beyond) so it meets up with the continuation
    /// line in the next measure without a visible gap.
    let continuesPastMeasure: Bool
}

/// Identifies one lyric syllable across the score — used as the key
/// for pre-computed per-lyric data (e.g. effective melisma ticks
/// after following ties forward).
struct MelismaLyricKey: Hashable {
    let staffIndex: Int
    let measureIndex: Int
    let voiceIndex: Int
    let elementIndex: Int
    let verseIndex: Int
}

extension LayoutEngine {
    /// Place elements of a measure in local measure coordinates.
    /// Returns the placed elements + the updated clef context.
    ///
    /// Layout strategy: non-timed leading elements (clef / key sig / time
    /// sig) are stacked left-to-right at fixed widths. Timed elements
    /// (chords and rests) are then positioned proportionally to their
    /// tick offset within the measure so the content fills the full
    /// stretched measure width.
    static func placeMeasureElements( // swiftlint:disable:this function_body_length
        measure: Measure,
        staffAddress: StaffAddress,
        measureIndex: Int,
        width: CGFloat,
        metrics: StaffMetrics,
        options: ScoreViewOptions = ScoreViewOptions(),
        activeClef: NotatedClef,
        activeKey: Int = 0,
        initialClefRawType: String? = nil,
        initialKeyForSynth: Int? = nil,
        headerSchedule: HeaderSchedule,
        tickColumns: [Int: CGFloat],
        division: Int,
        measureDuration: Fraction,
        drumLineMap: [Int: Int]? = nil,
        isLastMeasure: Bool = false,
        isFirstSystem: Bool = false,
        incomingMelismas: [MelismaContinuation] = [],
        effectiveMelismaTicks: [MelismaLyricKey: Int] = [:],
        coversBelowStaffSpanner: Bool = false,
        systemElements: [PositionedSystemElement] = [],
    ) -> (
        elements: [LayoutElement],
        invisibleElements: [LayoutElement],
        clef: NotatedClef,
        key: Int,
    ) {
        let staffMidY = metrics.staffHeight / 2 + metrics.sp * 2
        var out: [LayoutElement] = []
        // Parallel accumulator for hidden annotations that are still
        // laid out (because `options.showsInvisibleElements` is on) but
        // routed away from `out` so they don't print and don't affect
        // spacing / autoplace passes. See Task 0.7's `invisibleElements`.
        var invisibleOut: [LayoutElement] = []
        var currentClef = activeClef
        var currentKey = activeKey

        // --- Scan: time signature in this measure (for beam grouping) ---
        //
        // `beamGroups` needs the raw `TimeSignature` element (if present)
        // to compute beat boundaries and beam-group lengths. This scan is
        // separate from `measureDuration`: the latter is passed in from
        // the caller so the prevailing TS carries forward across measures
        // that lack an explicit `<TimeSignature>` element.
        var measureTimeSig: TimeSignature?
        for voice in measure.voices {
            for el in voice.elements {
                if case let .timeSignature(ts) = el {
                    measureTimeSig = ts
                    break
                }
            }
            if measureTimeSig != nil { break }
        }
        // `measureDuration` is passed in from the caller, which derives
        // it via `[Measure].effectiveMeasureDurations()` so the
        // prevailing time signature carries forward across measures that
        // lack an explicit `<TimeSignature>` element. Used to resolve any
        // `.measure` rest via `NoteDuration.resolved(in:)`.
        // --- Should we synthesize a leading clef? ---
        //
        // MuseScore omits explicit `<Clef>` in the first measure when the
        // default is implied by the instrument (e.g. treble for voice,
        // percussion for drums). Callers pass the staff's default raw
        // type via `initialClefRawType` on the first system; if no
        // explicit `.clef(...)` leads the voice, we synthesize one so
        // the staff is readable.
        let synthesizeLeadingClef: Bool
        if let rawType = initialClefRawType,
           !firstVoiceStartsWithClef(measure: measure)
        {
            synthesizeLeadingClef = true
            currentClef = NotatedClef(rawType: rawType)
        } else {
            synthesizeLeadingClef = false
        }
        // --- Should we synthesize a leading key signature? ---
        //
        // At the start of a continuation system, engraving convention
        // redraws the currently active key signature even if the
        // measure itself has no explicit `<KeySig>`.  `activeKey`
        // carries the current concert key (positive = sharps, etc.);
        // `initialKeyForSynth` is non-nil when the caller asks for the
        // synthesis.  We skip when the key is 0 (C major — no glyph).
        let synthesizeLeadingKeySig: Bool
        if let keyForSynth = initialKeyForSynth,
           keyForSynth != 0,
           !firstVoiceHasLeadingKeySig(measure: measure)
        {
            synthesizeLeadingKeySig = true
        } else {
            synthesizeLeadingKeySig = false
        }

        // --- Pass 2: emit elements for each voice ---
        //
        // Two independent multi-voice checks:
        //
        //   `hasMultiChordVoices`  — more than one voice contains at
        //       least one chord.  Drives stem-direction forcing (voice
        //       0/2 up, 1/3 down) and skipping the whole-measure rest
        //       centering.  Matches MuseScore's `hasVoices()` for stem
        //       direction.
        //   `hasMultiContentVoices` — more than one voice has ANY
        //       timed content (chord OR rest).  Drives rest y-offset
        //       so a voice 1 that holds only rests still gets shifted
        //       below voice 0's melody line; and drives whole-rest
        //       tick anchoring so centering doesn't drop the rest
        //       onto a melody note.
        let voicesWithChords = measure.voices.count(where: { v in
            v.elements.contains {
                if case let .chord(c) = $0, !c.notes.isEmpty {
                    return true
                }
                return false
            }
        })
        let voicesWithContent = measure.voices.count(where: { v in
            v.elements.contains {
                if case .chord = $0 { return true }
                return false
            }
        })
        let hasMultiChordVoices = voicesWithChords > 1
        let hasMultiContentVoices = voicesWithContent > 1
        let isMultiVoice = hasMultiChordVoices

        var remainingSynthClef = synthesizeLeadingClef
        var remainingSynthKeySig = synthesizeLeadingKeySig
        for (voiceIdx, voice) in measure.voices.enumerated() {
            var tickCursor = 0
            var inHeader = true
            var voiceChordOutIndex: [Int: Int] = [:]
            // Tick of each emitted chord, keyed by its index in `out`.
            // Populated alongside `voiceChordOutIndex` so the post-
            // beaming fermata clearance pass can map a chord's actual
            // (post-beam) stemOrigin.y back to the tick whose skyline
            // the fermata used during its initial placement.
            var chordTickByOutIndex: [Int: Int] = [:]
            // Fermata anchors recorded during the main switch loop so
            // the post-beaming pass can re-clear each fermata against
            // the chord's actual (beam-driven) stem tip. The static
            // `voiceChordNorthByTick` / `…SouthByTick` maps used at
            // emission time only know about per-chord standalone stem
            // extensions, not the longer (or shorter) stems produced
            // by the beaming pass.
            var fermataPostProcessAnchors: [(
                outIndex: Int,
                anchorTick: Int?,
                isBelow: Bool,
            )] = []
            // Parallel mapping for rest members. Used by
            // `emitTupletLabel` so a rest in a tuplet still
            // contributes to the bracket's horizontal span.
            var voiceRestOutIndex: [Int: Int] = [:]
            // Per-verse trail used to drop hyphens between adjacent
            // syllables of the same word ("Pa-ra-di-so" → 3 dashes).
            // Mirrors MuseScore's `LyricsLayout::layoutDashes`: when
            // the previous syllable was `begin`/`middle` and the
            // current is `middle`/`end`, dashes fill the gap between
            // them. Within-measure only for now; cross-measure
            // hyphens (when a word spans a barline) would need the
            // same continuation plumbing as melismas.
            struct LyricTrail {
                let centerX: CGFloat
                let textWidth: CGFloat
                let lyricsY: CGFloat
                let syllabic: Syllabic
            }
            var previousLyric: [Int: LyricTrail] = [:]
            // Pre-compute this voice's total ticks for the measure
            // so melisma emission can tell "ends inside" from
            // "crosses into next measure" without rescanning.
            let voiceTotalTicks: Int = voice.elements.reduce(0) { acc, el in
                switch el {
                case let .chord(c):
                    return acc + c.duration.resolved(in: measureDuration).ticks(division: division)
                default:
                    return acc
                }
            }

            // Forced stem direction for multi-voice measures.
            //
            // Drum staves additionally force the same voice-based rule
            // even when only one voice has chords: in MuseScore's
            // Drumset, every pitch carries a fixed `<voice>` (0/1) and
            // `<stem>` (up/down) that the input UI assigns at note
            // entry, so a properly authored drum measure has voice 0
            // chords intended for stem-up and voice 1 for stem-down
            // regardless of whether the other voice is currently
            // populated. The pitched-staff median rule would otherwise
            // flip stems on top-half drum lines (e.g. snare, mid toms).
            let isDrumStaff = drumLineMap != nil
            let forcedStem: StemDirection? = (isMultiVoice || isDrumStaff)
                ? (voiceIdx.isMultiple(of: 2) ? .up : .down)
                : nil
            // Rest y offset when multiple voices coexist — even if the
            // second voice only carries rests, we still need to pull
            // them out of the way of voice 0's melody.
            let restVoiceOffset: CGFloat = hasMultiContentVoices
                ? (
                    voiceIdx.isMultiple(of: 2)
                        ? -metrics.sp * 2
                        : metrics.sp * 2
                )
                : 0

            // Per-tick south-skyline of chords in this voice — the
            // visual lowest Y of the chord's noteheads (and stem,
            // for stem-down). Used to push dynamics below low
            // chords so the glyph doesn't sit on top of ledger-line
            // noteheads. Mirrors MuseScore's autoplace, where a
            // Dynamic below the staff nudges its Y until it clears
            // the chord skyline at the same segment plus
            // `Sid::dynamicsMinDistance` (≈ 0.5 sp).
            let voiceChordSouthByTick: [Int: CGFloat] = {
                var map: [Int: CGFloat] = [:]
                var t = 0
                for el in voice.elements {
                    guard case let .chord(chord) = el else { continue }
                    let ticks = chord.duration.resolved(in: measureDuration).ticks(division: division)
                    defer { t += ticks }
                    guard !chord.notes.isEmpty else { continue }
                    let steps: [Int] = chord.notes.map { note in
                        if let drumLine = drumLineMap?[note.pitch] {
                            return 4 - drumLine
                        }
                        return PitchStaffPosition.step(
                            midiPitch: note.pitch, tpc: note.tpc,
                            clef: currentClef,
                        ).step
                    }
                    guard let lowestStep = steps.min() else { continue }
                    let lowestNoteY = staffMidY
                        - CGFloat(lowestStep) * metrics.sp / 2
                    var south = lowestNoteY + metrics.sp * 0.5
                    let stemDir = forcedStem
                        ?? StemDirectionRule.direction(for: steps)
                    // Stem-down on a low chord (typical of voice 2 in
                    // a piano grand staff) extends below the lowest
                    // notehead by `defaultStemLength` measured from
                    // the HIGHEST note's center, mirroring
                    // `StemRenderer`.
                    if stemDir == .down, let highestStep = steps.max() {
                        let highestNoteY = staffMidY
                            - CGFloat(highestStep) * metrics.sp / 2
                        let stemEnd = highestNoteY
                            + metrics.defaultStemLength
                        south = max(south, stemEnd)
                    }
                    map[t] = max(map[t] ?? -.infinity, south)
                }
                return map
            }()

            // Per-tick north-skyline of chords in this voice — the
            // visual highest Y (smallest value) of the chord's
            // noteheads (and stem, for stem-up). Used to push fermata
            // glyphs above the chord so the SMuFL glyph clears
            // ledger-line noteheads, stem-up endpoints, flags, and
            // beams. Mirrors MuseScore's autoplace, where a Fermata
            // above the staff nudges its Y until it clears the
            // chord's north skyline at the same segment.
            let voiceChordNorthByTick: [Int: CGFloat] = {
                var map: [Int: CGFloat] = [:]
                var t = 0
                for el in voice.elements {
                    guard case let .chord(chord) = el else { continue }
                    let ticks = chord.duration.resolved(in: measureDuration).ticks(division: division)
                    defer { t += ticks }
                    guard !chord.notes.isEmpty else { continue }
                    let steps: [Int] = chord.notes.map { note in
                        if let drumLine = drumLineMap?[note.pitch] {
                            return 4 - drumLine
                        }
                        return PitchStaffPosition.step(
                            midiPitch: note.pitch, tpc: note.tpc,
                            clef: currentClef,
                        ).step
                    }
                    guard let highestStep = steps.max() else { continue }
                    let highestNoteY = staffMidY
                        - CGFloat(highestStep) * metrics.sp / 2
                    var north = highestNoteY - metrics.sp * 0.5
                    let stemDir = forcedStem
                        ?? StemDirectionRule.direction(for: steps)
                    // Stem-up on a high chord extends above the
                    // highest notehead by `defaultStemLength`
                    // measured from the LOWEST note's center,
                    // mirroring `StemRenderer`. A flag/beam adds
                    // ~0.5 sp of further vertical extent which the
                    // existing 0.5 sp buffer subsumes for v1.
                    if stemDir == .up, let lowestStep = steps.min() {
                        let lowestNoteY = staffMidY
                            - CGFloat(lowestStep) * metrics.sp / 2
                        let stemEnd = lowestNoteY
                            - metrics.defaultStemLength
                        north = min(north, stemEnd)
                    }
                    map[t] = min(map[t] ?? .infinity, north)
                }
                return map
            }()

            // Final lyric center Y for this voice — the max over
            // all chords' south-skyline-pushed Ys. Pre-computed
            // here (rather than ratcheted incrementally during
            // emission) so every chord's lyric uses the SAME Y;
            // otherwise earlier chords sit at a lower ratchet
            // value than later ones and the in-measure lyric row
            // is jagged.
            let voiceMaxLyricCenterY: CGFloat = {
                // Default 2 sp below staff; bumped further when a
                // below-staff spanner (hairpin, pedal) shares the
                // measure, so the spanner glyph sits between staff
                // and lyric (the MuseScore convention).
                var maxY = lyricBaseFloor(
                    staffMidY: staffMidY, metrics: metrics,
                    coversBelowStaffSpanner: coversBelowStaffSpanner,
                )
                for el in voice.elements {
                    guard case let .chord(chord) = el else { continue }
                    guard let avoidY = chordLyricAvoidY(
                        chord: chord,
                        forcedStem: forcedStem,
                        currentClef: currentClef,
                        drumLineMap: drumLineMap,
                        staffMidY: staffMidY,
                        metrics: metrics,
                    ) else { continue }
                    maxY = max(maxY, avoidY)
                }
                return maxY
            }()

            // Emit the synthesized leading clef exactly once, at the top
            // of the first voice to process it.
            if remainingSynthClef, let rawType = initialClefRawType {
                let synthAnchor: ClefAnchor? = isFirstSystem
                    ? .staffDefault(staffAddress)
                    : nil
                out.append(.clef(
                    rawType: rawType,
                    origin: CGPoint(
                        x: headerSchedule.clefX, y: staffMidY,
                    ),
                    anchor: synthAnchor,
                ))
                remainingSynthClef = false
            }
            // Emit the synthesized leading key signature once, after
            // the clef column.
            if remainingSynthKeySig, let k = initialKeyForSynth {
                out.append(.keySignature(
                    sharps: max(0, k),
                    flats: max(0, -k),
                    origin: CGPoint(
                        x: headerSchedule.keySigX, y: staffMidY,
                    ),
                ))
                remainingSynthKeySig = false
            }

            /// x-coordinate for a timed element starting at `tick`.
            /// Always consults the shared per-measure `tickColumns` map
            /// so notes at the same tick across different staves or
            /// voices land at exactly the same x — MuseScore's segment
            /// alignment.
            func timedX(atTick tick: Int) -> CGFloat {
                tickColumns[tick]
                    ?? (headerSchedule.contentStartX + metrics.sp)
            }

            // Tick where the most recently emitted chord BEGAN. Used
            // by the fermata case to look up the north/south skyline
            // when no following chord exists in the same voice.
            var lastEmittedChordTick: Int?

            for (voiceElemIdx, el) in voice.elements.enumerated() {
                switch el {
                case let .clef(clef):
                    // Slot-preservation: `currentClef` MUST be updated
                    // even when the clef is hidden — pitch / accidental
                    // / stem-direction passes downstream key off the
                    // active clef regardless of glyph visibility. Only
                    // the visual emission is routed by `.visible`.
                    currentClef = NotatedClef(rawType: clef.concertClefType)
                    guard clef.visible || options.showsInvisibleElements
                    else { break }
                    let clefX = inHeader ? headerSchedule.clefX
                        : timedX(atTick: tickCursor)
                    let veID = VoiceElementID(
                        staff: staffAddress,
                        measureIndex: measureIndex,
                        voiceIndex: voiceIdx,
                        elementIndex: voiceElemIdx,
                    )
                    let element = LayoutElement.clef(
                        rawType: clef.concertClefType,
                        origin: CGPoint(x: clefX, y: staffMidY),
                        anchor: .explicit(veID),
                    )
                    if clef.visible {
                        out.append(element)
                    } else {
                        invisibleOut.append(element)
                    }
                case let .keySignature(key):
                    // Slot-preservation: `currentKey` is the active
                    // signature for accidental rendering downstream;
                    // update it regardless of glyph visibility.
                    currentKey = key.concertKey
                    guard key.visible || options.showsInvisibleElements
                    else { break }
                    let keyX = inHeader ? headerSchedule.keySigX : timedX(atTick: tickCursor)
                    let element = LayoutElement.keySignature(
                        sharps: max(0, key.concertKey),
                        flats: max(0, -key.concertKey),
                        origin: CGPoint(x: keyX, y: staffMidY),
                    )
                    if key.visible {
                        out.append(element)
                    } else {
                        invisibleOut.append(element)
                    }
                case let .timeSignature(ts):
                    guard ts.visible || options.showsInvisibleElements
                    else { break }
                    let tsX = inHeader ? headerSchedule.timeSigX : timedX(atTick: tickCursor)
                    let element = LayoutElement.timeSignature(
                        numerator: ts.numerator,
                        denominator: ts.denominator,
                        origin: CGPoint(x: tsX, y: staffMidY),
                    )
                    if ts.visible {
                        out.append(element)
                    } else {
                        invisibleOut.append(element)
                    }
                case let .barLine(b):
                    guard b.visible || options.showsInvisibleElements
                    else { break }
                    // A trailing `<BarLine>` appears AFTER the voice's
                    // last chord/rest, so `tickCursor` sits at the
                    // measure's end tick. `tickColumns` only carries
                    // entries for ticks that host content, so end-tick
                    // lookups miss — falling back through `timedX`
                    // would land the bar at `contentStartX + sp`
                    // (the start of the measure body). Mirror the
                    // implicit-trailing-barline path and pin the bar
                    // to `width - sp/2` whenever the cursor sits on
                    // a non-content tick. Mid-measure bars (rare)
                    // still resolve via `tickColumns`.
                    let barX: CGFloat
                    if inHeader {
                        barX = metrics.sp
                    } else if let columnX = tickColumns[tickCursor] {
                        barX = columnX
                    } else {
                        barX = width - metrics.sp / 2
                    }
                    let element = LayoutElement.barLine(
                        subtype: b.subtype,
                        origin: CGPoint(x: barX, y: staffMidY),
                    )
                    if b.visible {
                        out.append(element)
                    } else {
                        invisibleOut.append(element)
                    }
                case let .chord(r) where r.notes.isEmpty:
                    inHeader = false
                    let (restBase, _) = DurationInterpretation.split(
                        r.duration,
                    )
                    // Whole rest hangs from the 2nd line from the top
                    // (step +2). Half rest sits on the middle line
                    // (step 0 = staffMidY). Others center on the
                    // middle line. In multi-voice mode, offset by
                    // restVoiceOffset so voices don't overlap.
                    let restY: CGFloat
                    switch restBase {
                    case .whole:
                        restY = staffMidY - metrics.sp + restVoiceOffset
                    default:
                        restY = staffMidY + restVoiceOffset
                    }
                    // Center only true measure-fill markers
                    // (`NoteDuration.measure`). Typed `.whole`
                    // rests carry an explicit duration and sit on
                    // their start beat — MuseScore's data model:
                    // a "centered" rest in any voice is authored as
                    // `<durationType>measure</…>`, not
                    // `<durationType>whole</…>`. With
                    // `NoteDuration.measure` present in the model,
                    // this distinction is honored.
                    let isMeasureRest: Bool = {
                        if case .measure = r.duration { return true }
                        return false
                    }()
                    let restX: CGFloat
                    if isMeasureRest {
                        // Center the rest in the measure's chord
                        // area: midpoint of [contentStart,
                        // width − trailingPadding]. Must track
                        // `minimumMeasureWidth.rightPadding` and
                        // `chordSpacingTickToX.trailingGap` —
                        // otherwise the rest drifts off-center
                        // whenever those constants are tuned.
                        let trailingPad = metrics.sp * 1
                        restX = (
                            headerSchedule.contentStartX
                                + width - trailingPad,
                        ) / 2
                    } else {
                        restX = timedX(atTick: tickCursor)
                    }
                    let restID = RestID(
                        staff: staffAddress,
                        measureIndex: measureIndex,
                        voiceIndex: voiceIdx,
                        elementIndex: voiceElemIdx,
                    )
                    // Staff lines span y = sp*2 (top) to y = sp*6
                    // (bottom). When a whole / half rest lands
                    // outside that range — e.g. voice-2 whole
                    // rest pushed below the staff — MuseScore
                    // draws its leger-line variant glyph so the
                    // rest comes with its own short stroke.
                    let staffTopLocal = metrics.sp * 2
                    let staffBottomLocal = metrics.sp * 2
                        + metrics.staffHeight
                    let needsLeger = (
                        restBase == .whole
                            || restBase == .half,
                    )
                        && (
                            restY < staffTopLocal
                                || restY > staffBottomLocal
                        )
                    let restElement = LayoutElement.rest(
                        duration: r.duration,
                        origin: CGPoint(x: restX, y: restY),
                        voiceIndex: voiceIdx,
                        restID: restID,
                        hasLegerLine: needsLeger,
                    )
                    // Visibility: a `Chord` with empty notes is the
                    // rest case (an actual rest, not a chord). Hidden
                    // rests are routed by `chord.visible`; the slot is
                    // preserved by the unconditional `tickCursor`
                    // advance below.
                    if r.visible {
                        voiceRestOutIndex[voiceElemIdx] = out.count
                        out.append(restElement)
                    } else if options.showsInvisibleElements {
                        // Route the hidden rest into the invisible
                        // accumulator. Do NOT register
                        // `voiceRestOutIndex` for invisibleOut entries —
                        // downstream tuplet / etc. passes index `out`
                        // only. A hidden rest doesn't visually
                        // contribute to a tuplet bracket; acceptable v1.
                        invisibleOut.append(restElement)
                    }
                    // else: toggle off + hidden — skip emission. Slot
                    // is preserved by the unconditional tick advance
                    // below.
                    tickCursor += r.duration.resolved(in: measureDuration).ticks(division: division)
                case let .chord(chord):
                    inHeader = false
                    // Every element at a shared tick lives at the same
                    // x. Flag glyphs extend ~1 sp to the right of the
                    // stem, but that's a visual-only concern — shifting
                    // the notehead itself would desynchronise flagged
                    // chords from rests (and from notes in other
                    // voices) that share the same tick.
                    let chordX = timedX(atTick: tickCursor)
                    let preliminaryNotes = chord.notes.enumerated().map { noteIdx, note -> LayoutChordNote in
                        // For percussion staves, use the drum map's
                        // <line> value to position the notehead
                        // instead of the pitched diatonic formula.
                        // MuseScore line L maps to step = 4 − L
                        // (line 0 = top = step +4, line 4 = middle
                        // = step 0, line 8 = bottom = step −4).
                        let step: Int
                        if let drumLine = drumLineMap?[note.pitch] {
                            step = 4 - drumLine
                        } else {
                            step = PitchStaffPosition.step(
                                midiPitch: note.pitch, tpc: note.tpc,
                                clef: currentClef,
                            ).step
                        }
                        let y = staffMidY - CGFloat(step) * metrics.sp / 2
                        let id = NoteID(
                            staff: staffAddress,
                            measureIndex: measureIndex,
                            voiceIndex: voiceIdx,
                            elementIndex: voiceElemIdx,
                            noteIndexInChord: noteIdx,
                        )
                        return LayoutChordNote(
                            noteID: id,
                            step: step,
                            accidental: note.accidental,
                            origin: CGPoint(x: chordX, y: y),
                            tieForward: note.tieForward,
                            tieBack: note.tieBack,
                            hasGlissando: note.glissando != nil,
                            headType: note.headType,
                            // Pure "source hidden" flag — renderers
                            // consult `LayoutSystem.showsInvisibleElements`
                            // to decide whether to gray or skip per-note.
                            isInvisible: !note.visible,
                            color: note.elementProperties.color,
                            accidentalBracket: note.accidentalBracket,
                            parentheses: note.parentheses,
                        )
                    }
                    let stem = forcedStem
                        ?? StemDirectionRule.direction(
                            for: preliminaryNotes.map(\.step),
                        )
                    let chordNotes = applyChordMirroring(
                        preliminaryNotes, stem: stem,
                    )
                    let stemExtension = tremoloStemExtension(
                        for: chord, metrics: metrics,
                    )
                    // Pass the FULL `chordNotes` list (per-note
                    // `isInvisible` flags set) so stem / beam geometry
                    // is computed from every source note regardless of
                    // per-note visibility. Renderers consult the system's
                    // `showsInvisibleElements` to decide per-note whether
                    // to gray or skip the notehead.
                    let chordMag: CGFloat = chord.notes.contains { $0.isSmall }
                        ? options.smallNoteMag
                        : 1.0
                    let mainElement: LayoutElement = .chord(
                        notes: chordNotes,
                        duration: chord.duration,
                        stem: stem,
                        stemOrigin: CGPoint(x: chordX, y: staffMidY),
                        hasArpeggio: chord.arpeggio != nil,
                        arpeggioRawType: chord.arpeggio.flatMap(arpeggioSubtype),
                        isBeamed: false,
                        voiceIndex: voiceIdx,
                        stemExtension: stemExtension,
                        stemIsInvisible: !chord.stemVisible,
                        mag: chordMag,
                    )
                    // MuseScore stores Stem visibility independently from
                    // Note visibility (see <Chord><Stem><visible> in mscx).
                    // Hiding all noteheads in a chord must NOT suppress
                    // the stem/flag/beam — only `chord.visible == false`
                    // suppresses the whole chord. Per-notehead invisibility
                    // is handled downstream via `LayoutChordNote.isInvisible`;
                    // the renderer skips drawing those noteheads (toggle off)
                    // or grays them (toggle on) while leaving stem geometry
                    // derived from the full note list.
                    let chordFullyHidden = !chord.visible
                    let graceW = LayoutEngine.graceWidth(sp: metrics.sp)
                    let mag = options.graceNoteMag
                    for (gIdx, g) in chord.graceNotesBefore.enumerated() {
                        let relX = -graceW * CGFloat(chord.graceNotesBefore.count - gIdx)
                        let layoutNotes = makeGraceLayoutNotes(
                            grace: g, atX: chordX + relX,
                            staffMidY: staffMidY, metrics: metrics,
                            currentClef: currentClef,
                            staffAddress: staffAddress,
                            measureIndex: measureIndex,
                            voiceIdx: voiceIdx,
                            voiceElemIdx: voiceElemIdx,
                            graceIdx: gIdx, isAfter: false,
                            drumLineMap: drumLineMap,
                            showsInvisibleElements: options.showsInvisibleElements,
                        )
                        let graceStem = StemDirectionRule.direction(
                            for: layoutNotes.map(\.step),
                        )
                        out.append(.graceChord(
                            notes: layoutNotes,
                            duration: g.duration,
                            stem: graceStem,
                            stemOrigin: CGPoint(x: chordX + relX, y: staffMidY),
                            relativeX: relX,
                            hasSlash: g.graceType == .acciaccatura,
                            mag: mag,
                            voiceIndex: voiceIdx,
                        ))
                    }
                    if !chordFullyHidden {
                        voiceChordOutIndex[voiceElemIdx] = out.count
                        chordTickByOutIndex[out.count] = tickCursor
                        out.append(mainElement)
                    } else if options.showsInvisibleElements {
                        // Hidden chord with toggle on: route the main
                        // element into invisibleOut. Satellite emissions
                        // (articulations, arpeggio, tremolo, lyrics) for
                        // a fully-invisible chord still go to `out`
                        // below; in practice MuseScore hides them too
                        // when their host chord is hidden, but those
                        // passes already check `<visible>` on their own
                        // model objects (lyric / arpeggio / etc.), and
                        // the user's visual test (a wholly-hidden chord)
                        // is satisfied by suppressing the main notehead
                        // + stem + flag/beam. We do NOT register
                        // `voiceChordOutIndex` / `chordTickByOutIndex`
                        // because downstream beam / tuplet / glissando
                        // passes index `out` only and shouldn't see a
                        // fully-invisible chord.
                        invisibleOut.append(mainElement)
                    }
                    // else: toggle off + fully hidden — skip emission.
                    // Slot is preserved by the unconditional tick
                    // advance at the end of this case.
                    // Chord-level articulation glyphs. Placement mirrors
                    // MuseScore's `Chord::layoutArticulations` — see
                    // `articulationElements(for:…)`. Re-placed after the beam
                    // pass fixes a beamed chord's stem direction.
                    out.append(contentsOf: Self.articulationElements(
                        for: chord.articulations,
                        stem: stem,
                        noteYs: chordNotes.map(\.origin.y),
                        chordX: chordX,
                        staffMidY: staffMidY,
                        metrics: metrics,
                    ))
                    for (gIdx, g) in chord.graceNotesAfter.enumerated() {
                        let relX = graceW * CGFloat(gIdx + 1)
                        let layoutNotes = makeGraceLayoutNotes(
                            grace: g, atX: chordX + relX,
                            staffMidY: staffMidY, metrics: metrics,
                            currentClef: currentClef,
                            staffAddress: staffAddress,
                            measureIndex: measureIndex,
                            voiceIdx: voiceIdx,
                            voiceElemIdx: voiceElemIdx,
                            graceIdx: gIdx, isAfter: true,
                            drumLineMap: drumLineMap,
                            showsInvisibleElements: options.showsInvisibleElements,
                        )
                        let graceStem = StemDirectionRule.direction(
                            for: layoutNotes.map(\.step),
                        )
                        out.append(.graceChord(
                            notes: layoutNotes,
                            duration: g.duration,
                            stem: graceStem,
                            stemOrigin: CGPoint(x: chordX + relX, y: staffMidY),
                            relativeX: relX,
                            hasSlash: false,
                            mag: mag,
                            voiceIndex: voiceIdx,
                        ))
                    }
                    // Jazz/brass inflection lines (fall / doit / plop /
                    // scoop). C++: `TLayout::layoutChordLine`.
                    let chordLineParts = Self.chordLineElements(
                        for: chord.chordLines,
                        chordNotes: chordNotes,
                        chordX: chordX,
                        dots: DurationInterpretation.split(chord.duration).dots,
                        stem: stem,
                        staffMidY: staffMidY,
                        // The chord's own magnification — C++:
                        // `chord()->intrinsicMag()`. NOT `mag`, which is
                        // the enclosing grace-note scale (0.6).
                        mag: chordMag,
                        metrics: metrics,
                    )
                    out.append(contentsOf: chordLineParts.visible)
                    invisibleOut.append(contentsOf: chordLineParts.invisible)
                    if let arp = chord.arpeggio,
                       arp.visible || options.showsInvisibleElements
                    {
                        let ys = chordNotes.map(\.origin.y)
                        let top = ys.min() ?? staffMidY
                        let bot = ys.max() ?? staffMidY
                        let wiggle = LayoutElement.arpeggioWiggle(
                            top: CGPoint(x: chordX, y: top),
                            bottom: CGPoint(x: chordX, y: bot),
                            subtype: arpeggioSubtype(arp),
                        )
                        if arp.visible {
                            out.append(wiggle)
                        } else {
                            invisibleOut.append(wiggle)
                        }
                    }
                    if let trem = chord.tremolo {
                        if let bars = makeTremoloBarsElement(
                            tremolo: trem,
                            duration: chord.duration,
                            chordX: chordX,
                            chordNotes: chordNotes,
                            stem: stem,
                            stemExtension: stemExtension,
                            staffMidY: staffMidY,
                            metrics: metrics,
                            currentClef: currentClef,
                            currentVoiceElements: voice.elements,
                            currentVoiceElemIdx: voiceElemIdx,
                            currentTick: tickCursor,
                            measureDuration: measureDuration,
                            division: division,
                            timedX: timedX,
                        ) {
                            out.append(bars)
                        }
                    }
                    // Lyrics: emit the syllable text + (if the lyric
                    // extends beyond this chord) a melisma rule that
                    // stretches to the end of the last note it covers.
                    let chordTicks = chord.duration
                        .resolved(in: measureDuration)
                        .ticks(division: division)
                    // Use the voice's pre-computed max south-driven
                    // Y so every chord in the measure shares the
                    // same lyric center (within-measure horizontal
                    // alignment). The system-wide post-pass in
                    // `LayoutEngine.layout` then aligns this Y
                    // across measures of the same system.
                    let chordLyricCenterY = voiceMaxLyricCenterY
                    for (verseIdx, lyric) in chord.lyrics.enumerated() {
                        guard !lyric.text.isEmpty else { continue }
                        // Hidden lyrics: drop entirely when toggle is
                        // off (print-by-default); when toggle is on
                        // route the syllable text to `invisibleOut`
                        // (NOT `out`) so the hidden glyph is exposed
                        // for invisible-overlay rendering but does not
                        // print. Decorations (hyphens / melisma rule)
                        // are NOT emitted for hidden lyrics — they
                        // would otherwise dangle visually without their
                        // anchor syllable. The `previousLyric` trail is
                        // still updated so a following visible
                        // syllable in the same verse hyphenates from
                        // the hidden lyric's slot rather than reaching
                        // back to an earlier visible syllable.
                        guard lyric.visible || options.showsInvisibleElements
                        else {
                            let textWidth = Self.lyricsTextWidth(
                                lyric.text, sp: metrics.sp,
                            )
                            previousLyric[verseIdx] = LyricTrail(
                                centerX: chordX,
                                textWidth: textWidth,
                                lyricsY: chordLyricCenterY
                                    + CGFloat(verseIdx) * metrics.sp * 1.7,
                                syllabic: lyric.syllabic,
                            )
                            continue
                        }
                        // Verse stride 1.7 sp keeps multi-verse
                        // stacks compact while still clearing
                        // ascender/descender overlap between
                        // adjacent verse lines (≈
                        // `Sid::lyricsLineHeight = 1.0` × font
                        // height).
                        let lyricsY = chordLyricCenterY
                            + CGFloat(verseIdx) * metrics.sp * 1.7
                        let lyricElement = LayoutElement.textMark(
                            kind: .lyrics(color: lyric.elementProperties.color),
                            text: lyric.text,
                            origin: CGPoint(x: chordX, y: lyricsY),
                        )
                        if lyric.visible {
                            out.append(lyricElement)
                        } else {
                            invisibleOut.append(lyricElement)
                        }
                        let textWidth = Self.lyricsTextWidth(
                            lyric.text, sp: metrics.sp,
                        )
                        // Hyphens between this syllable and the
                        // previous one in the same verse. Only emitted
                        // when both endpoints are visible (a hidden
                        // syllable on either end takes the early
                        // `continue` above and never reaches here, so
                        // the test here is simply that the current
                        // lyric is visible — the previous one was too
                        // by induction).
                        if lyric.visible,
                           let prev = previousLyric[verseIdx],
                           connectsWithHyphen(
                               prev: prev.syllabic,
                               curr: lyric.syllabic,
                           )
                        {
                            let prevRight = prev.centerX
                                + prev.textWidth / 2
                                + metrics.sp * 0.3
                            let currLeft = chordX - textWidth / 2
                                - metrics.sp * 0.3
                            emitLyricHyphens(
                                fromX: prevRight,
                                toX: currLeft,
                                y: lyricsY,
                                metrics: metrics,
                                out: &out,
                            )
                        }
                        previousLyric[verseIdx] = LyricTrail(
                            centerX: chordX,
                            textWidth: textWidth,
                            lyricsY: lyricsY,
                            syllabic: lyric.syllabic,
                        )
                        // `<ticks>N</ticks>` in MuseScore marks a
                        // melisma whose visual rule reaches the
                        // chord that starts at `anchor.tick + N`.
                        // Any positive value means "draw a melisma
                        // line up to that target chord" — even when
                        // it equals the anchor chord's own duration
                        // (in which case the target is whatever
                        // chord follows the anchor).
                        if lyric.visible, lyric.ticks > 0 {
                            // `>=`: a melisma that lands exactly on
                            // the barline still needs to extend past
                            // it so the boundary-cap continuation in
                            // the next measure (see
                            // `appendContinuations`) meets it.
                            let continuesPastMeasure =
                                tickCursor + lyric.ticks
                                    >= voiceTotalTicks
                            // Drop the rule down to roughly the
                            // underscore baseline of the lyric font
                            // (~`sp * 0.9` below the center anchor
                            // we use for the syllable text). Matches
                            // MuseScore's "at baseline + underline
                            // offset" placement, see
                            // `melismaLineYOffset` below.
                            let melismaLineY = lyricsY
                                + Self.melismaLineYOffset(sp: metrics.sp)
                            emitMelismaLine(
                                chordX: chordX,
                                lyricText: lyric.text,
                                lyricTicks: lyric.ticks,
                                lyricsY: melismaLineY,
                                tickCursor: tickCursor,
                                chordTicks: chordTicks,
                                tickColumns: tickColumns,
                                headerContentStartX:
                                headerSchedule.contentStartX,
                                measureWidth: width,
                                continuesPastMeasure: continuesPastMeasure,
                                metrics: metrics,
                                out: &out,
                            )
                        }
                    }
                    lastEmittedChordTick = tickCursor
                    tickCursor += chordTicks
                case let .dynamic(d):
                    // Dynamics sit below-left of the note they apply to
                    // (i.e. the next timed element at the current tick).
                    // Shift 1 sp left so the label doesn't overlap the
                    // following chord's notehead or stem.
                    guard d.visible || options.showsInvisibleElements
                    else { break }
                    let baseX = inHeader
                        ? headerSchedule.contentStartX
                        : timedX(atTick: tickCursor)
                    // Default Y: 4 sp below the staff midline (= 2 sp
                    // below the bottom staff line). When the anchor
                    // chord at the same tick extends below the staff
                    // (low ledger lines, stem-down low chord), push
                    // the Y down so the SMuFL glyph clears the chord
                    // skyline. Anchor `.leading` puts the glyph center
                    // at `origin.y` and the glyph height is ~4 sp, so
                    // a center Y of `chordSouth + 2.5 sp` leaves
                    // ~0.5 sp of clearance above the glyph top —
                    // matching MuseScore's `Sid::dynamicsMinDistance`.
                    let defaultDynY = staffMidY + metrics.sp * 4
                    let chordSouth = voiceChordSouthByTick[tickCursor]
                        ?? -.infinity
                    let chordAvoid = chordSouth + metrics.sp * 2.5
                    let dynY = max(defaultDynY, chordAvoid)
                    let dynamicElement = LayoutElement.textMark(
                        kind: .dynamic,
                        text: d.subtype,
                        origin: CGPoint(
                            x: baseX - metrics.sp,
                            y: dynY,
                        ),
                    )
                    if d.visible {
                        out.append(dynamicElement)
                    } else {
                        invisibleOut.append(dynamicElement)
                    }
                case let .fermata(f):
                    // Hidden fermata: drop entirely when the toggle is
                    // off; otherwise build the element below and route
                    // it into `invisibleOut`. Routing to `invisibleOut`
                    // skips the beam-stemtip post-process refinement
                    // (which mutates `out` by outIndex) — that's
                    // acceptable for hidden glyphs since the
                    // `anchorY` computed here (chord skyline +
                    // visualGap) is already collision-free against the
                    // pre-beam estimate; the refinement only nudges
                    // visible fermatas down further when the beam
                    // endpoint extends past the standalone-stem
                    // estimate. Hidden fermatas don't print, so a
                    // slightly less-refined Y in the invisible overlay
                    // is fine.
                    guard f.visible || options.showsInvisibleElements
                    else { break }
                    // Anchor to the chord/rest the fermata applies to.
                    // Forward search first (canonical MusicXML order:
                    // fermata before chord). Backward fallback handles
                    // MSCX layouts where Fermata appears as a sibling
                    // after Chord. Mirrors the MIDI anchor rule in
                    // `FermataRanges.collect`.
                    var lookaheadTick = tickCursor
                    var forwardChordTick: Int?
                    var forwardChordX: CGFloat?
                    for j in (voiceElemIdx + 1) ..< voice.elements.count {
                        let next = voice.elements[j]
                        switch next {
                        case .chord:
                            forwardChordTick = lookaheadTick
                            forwardChordX = timedX(atTick: lookaheadTick)
                        case let .locationShift(delta):
                            lookaheadTick += delta.ticks(division: division)
                            continue
                        default:
                            continue
                        }
                        break
                    }
                    let anchorX = forwardChordX
                        ?? lastChordOrRestX(in: out)
                        ?? (
                            inHeader
                                ? headerSchedule.contentStartX
                                : timedX(atTick: tickCursor)
                        )
                    // Y placement: subtype suffix selects which
                    // skyline to clear. "Below" mirrors using south;
                    // anything else (canonical "Above" / unspecified)
                    // uses north. Default Y is 1 sp clear of the
                    // staff; chord skyline + clearance wins when the
                    // chord pokes into that space.
                    //
                    // Fermata SMuFL glyphs are drawn with anchor
                    // .center via SwiftUI Text (see
                    // GraphicsContext+Glyph.swift), which aligns the
                    // font's TYPOGRAPHIC bbox (ascent + descent) to
                    // origin.y — NOT the visible glyph. Bravura's
                    // ascent/descent are highly asymmetric, so the
                    // visible glyph sits ~1.4 sp BELOW origin.y in
                    // screen coords (not centered on it). Use measured
                    // offsets via `FermataGlyphMetrics` so the visible
                    // glyph EDGE — not its typographic bbox — clears
                    // the chord skyline by the visual gap.
                    let anchorTick = forwardChordTick
                        ?? lastEmittedChordTick
                    let isBelow = f.subtype.hasSuffix("Below")
                    let visualGap = metrics.sp * 0.5
                    let anchorY: CGFloat
                    if isBelow {
                        let defaultY = staffMidY + metrics.sp * 3
                        let chordSouth = anchorTick.flatMap {
                            voiceChordSouthByTick[$0]
                        } ?? -.infinity
                        // glyph TOP in screen = origin.y + topOffset.
                        // Want: origin.y + topOffset >= chordSouth + gap.
                        let topOffset =
                            FermataGlyphMetrics.below.topOffset * metrics.sp
                        let needed = chordSouth + visualGap - topOffset
                        anchorY = max(defaultY, needed)
                    } else {
                        let defaultY = staffMidY - metrics.sp * 3
                        let chordNorth = anchorTick.flatMap {
                            voiceChordNorthByTick[$0]
                        } ?? .infinity
                        // glyph BOTTOM in screen = origin.y + bottomOffset.
                        // Want: origin.y + bottomOffset <= chordNorth - gap.
                        let bottomOffset =
                            FermataGlyphMetrics.above.bottomOffset * metrics.sp
                        let needed = chordNorth - visualGap - bottomOffset
                        anchorY = min(defaultY, needed)
                    }
                    let fermataElement = LayoutElement.fermata(
                        subtype: f.subtype,
                        origin: CGPoint(x: anchorX, y: anchorY),
                    )
                    if f.visible {
                        // Only visible fermatas participate in the
                        // beam-stemtip post-process pass — that pass
                        // indexes into `out` directly and is purely a
                        // visual refinement.
                        fermataPostProcessAnchors.append((
                            outIndex: out.count,
                            anchorTick: anchorTick,
                            isBelow: isBelow,
                        ))
                        out.append(fermataElement)
                    } else {
                        invisibleOut.append(fermataElement)
                    }
                case .measureRepeat:
                    out.append(.measureRepeat(
                        count: 1,
                        origin: CGPoint(x: width / 2, y: staffMidY),
                    ))
                case .spanner:
                    // Resolved at system level in the spanner-attach pass.
                    break
                case let .locationShift(delta):
                    // Voice-level cursor shift. Adds the location's
                    // fractional delta to `tickCursor` so the next
                    // non-temporal element (text mark, dynamic,
                    // tempo, rehearsal mark) attaches at the
                    // shifted tick. Mirrors MuseScore's
                    // `setLocation` behavior during voice read.
                    tickCursor += delta.ticks(division: division)
                case let .harmony(harmony):
                    // Hidden chord symbols contribute neither glyphs
                    // nor width — drop before measurement so the
                    // pre-spacing pass and autoplace stacking ignore
                    // them. Playback (`harmony.play`) is independent
                    // of visibility. When `showsInvisibleElements` is
                    // on we still BUILD the element below, but route it
                    // into `invisibleOut` (NOT `out`) so the autoplace /
                    // stacking passes that mutate `out` continue to
                    // ignore it — hidden harmony must not widen the bar.
                    guard harmony.visible || options.showsInvisibleElements
                    else { break }
                    // Anchor at the next timed-element column (or
                    // header start while still in the header). Same
                    // anchoring rule as .staffText so multiple
                    // harmonies at the same tick share an X column
                    // (which the autoplace stacking pass relies on).
                    let stX = inHeader
                        ? headerSchedule.contentStartX
                        : timedX(atTick: tickCursor)
                    let runs = HarmonyRendering.runs(
                        for: harmony, metrics: metrics,
                    )
                    let width = HarmonyRendering.width(of: runs)
                    // staffMidY → staffTop is `staffMidY - sp * 2`
                    // (5-line staff). Shifting by harmonyPlacementAbove
                    // (-2.5 sp) puts the symbol just clear of the top
                    // line. The author's `<offset y>` adds on top.
                    let staffTopLocal = staffMidY - metrics.sp * 2
                    let yLocal = staffTopLocal
                        + metrics.harmonyPlacementAbove
                        + CGFloat(harmony.offsetY) * metrics.sp
                    let anchorX = Double(
                        stX + CGFloat(harmony.offsetX) * metrics.sp,
                    )
                    let harmonyElement = LayoutElement.harmony(LayoutHarmony(
                        harmony: harmony,
                        anchorX: anchorX,
                        y: Double(yLocal),
                        runs: runs,
                        width: width,
                    ))
                    if harmony.visible {
                        out.append(harmonyElement)
                    } else {
                        invisibleOut.append(harmonyElement)
                    }
                case let .breath(b):
                    // Hidden breath: drop entirely when the toggle is
                    // off; otherwise build the element below and route
                    // it into `invisibleOut`. Same visibility wiring
                    // as `.fermata`.
                    guard b.visible || options.showsInvisibleElements
                    else { break }
                    // X placement: anchor breath to the FOLLOWING chord,
                    // not the midpoint. MuseScore reads breath as
                    // belonging to the next chord (similar to how an
                    // accidental sits left of its notehead). Glyph's
                    // right edge sits a small gap before the next
                    // chord's X.
                    // Account for THIS breath's own glyph reservation
                    // + pause when looking ahead — the next chord's
                    // `tickColumns` entry was built by the spacing
                    // pass at the post-breath tick.
                    let breathGlyphReservationTicks = 120
                    let breathExtraTicks: Int = {
                        var t = breathGlyphReservationTicks
                        if b.pause > 0 {
                            // TODO: multi-tempo — sample the timeline
                            // at the breath's tick. v1 hard-codes 2.0
                            // bps.
                            let bps = 2.0
                            t += Int(
                                (b.pause * bps * Double(division))
                                    .rounded(),
                            )
                        }
                        return t
                    }()
                    var lookaheadTick = tickCursor + breathExtraTicks
                    var nextChordX: CGFloat?
                    for j in (voiceElemIdx + 1) ..< voice.elements.count {
                        let next = voice.elements[j]
                        switch next {
                        case .chord:
                            nextChordX = timedX(atTick: lookaheadTick)
                        case let .locationShift(delta):
                            lookaheadTick += delta.ticks(division: division)
                            continue
                        default:
                            continue
                        }
                        break
                    }
                    // Glyph advance — approximate via the bbox width.
                    // The actual advance for breath/caesura glyphs is
                    // small (~1-1.5 sp); use a conservative fallback
                    // when metrics aren't available.
                    let glyphOffsets = BreathGlyphMetrics.offsets(forKind: b.kind)
                    let bravuraEm = LayoutFont(
                        face: SMuFLFamily.bravura, pointSize: 4,
                    )
                    let codepoint = UInt16(
                        BreathGlyph.codepoint(forKind: b.kind),
                    )
                    let glyphAdvanceSp = FontMetrics.provider
                        .glyphPathBoundingBox(
                            font: bravuraEm, codepoint: codepoint,
                        )?.width ?? 1.0

                    let gapBeforeNextSp: CGFloat = 0.5
                    let originX: CGFloat
                    if let nx = nextChordX {
                        // Right-align: glyph's visible right edge sits
                        // `gapBeforeNextSp` sp left of the next chord.
                        // With anchor-.center, origin.x is the typographic
                        // CENTER, so subtract half the glyph advance.
                        let glyphRightX = nx - gapBeforeNextSp * metrics.sp
                        originX = glyphRightX
                            - (glyphAdvanceSp / 2) * metrics.sp
                    } else {
                        // No next chord in this voice — breath sits
                        // at the end of the measure, just before the
                        // bar line. MuseScore right-aligns the glyph
                        // to the bar line with a small gap, mirroring
                        // how breaths placed BETWEEN chords right-
                        // align to the next chord. The bar line lands
                        // at `width - sp/2` (see the `.barLine` arm
                        // ~line 505 for the fallback that owns this
                        // constant).
                        let barLineX = width - metrics.sp / 2
                        let glyphRightX = barLineX
                            - gapBeforeNextSp * metrics.sp
                        originX = glyphRightX
                            - (glyphAdvanceSp / 2) * metrics.sp
                    }
                    // Y placement:
                    // - Breath marks: target the visible BOTTOM edge
                    //   `0.5 sp` above the top staff line so the
                    //   glyph hangs JUST above the staff.
                    // - Caesuras: center the visible glyph on the
                    //   top staff line (MuseScore convention; the
                    //   caesura crosses through the line).
                    // With anchor-.center, the visible bottom edge
                    // sits at `origin.y + bottomOffset * sp` and the
                    // visible top edge at `origin.y + topOffset * sp`,
                    // so origin.y for bottom-clearance is
                    //   originY = targetBottomY - bottomOffset * sp
                    // and origin.y for visible-center is
                    //   originY = targetCenterY - (bottomOffset + topOffset)/2 * sp.
                    let staffTopY = staffMidY - metrics.sp * 2
                    let originY: CGFloat
                    switch b.kind {
                    case .breathMark:
                        let clearanceSp: CGFloat = 0.5
                        let targetBottomY = staffTopY - clearanceSp * metrics.sp
                        originY = targetBottomY
                            - glyphOffsets.bottomOffset * metrics.sp
                    case .caesura:
                        let visibleCenterOffsetSp =
                            (glyphOffsets.bottomOffset + glyphOffsets.topOffset) / 2
                        originY = staffTopY - visibleCenterOffsetSp * metrics.sp
                    }
                    let breathElement = LayoutElement.breath(
                        kind: b.kind,
                        origin: CGPoint(x: originX, y: originY),
                    )
                    if b.visible {
                        out.append(breathElement)
                    } else {
                        invisibleOut.append(breathElement)
                    }
                    // Advance the tick cursor by the breath's MIDI
                    // tick budget so subsequent chord X lookups in
                    // `tickColumns` use the post-pause tick. This
                    // keeps the layout's tick→X mapping in sync with
                    // MIDI's tick advancement (see
                    // `MidiRenderer+Voice.swift`'s `.breath` arm), so
                    // the playback cursor crosses the silence at the
                    // natural visual rate instead of racing across an
                    // undersized layout gap.
                    //
                    // TODO: multi-tempo scores — sample the tempo
                    // timeline at this breath's tick rather than
                    // hard-coding 2.0 bps (120 BPM). The current
                    // fixture is constant-tempo so the simplification
                    // is acceptable for v1.
                    // Mirrors the same advance in
                    // `LayoutEngine+Spacing.swift`'s `.breath` arm —
                    // the reservation + pause-derived ticks computed
                    // above as `breathExtraTicks`.
                    tickCursor += breathExtraTicks
                }
            }

            // Glissando emission used to happen here, pairing each
            // glissando-bearing note with the next chord in the SAME
            // measure/voice — a glissando on the last chord of a
            // measure had no "next chord" left to pair with and was
            // silently dropped. Glissandi are now resolved in a
            // document-wide post-pass (mirroring ties) that can look
            // past measure/system boundaries — see
            // `LayoutEngine.resolveGlissandi` / `.attachGlissandi` in
            // `LayoutEngine+Glissandi.swift`, hooked in from
            // `LayoutEngine.layout(...)`.

            // Beaming pass for this voice.
            let groups = beamGroups(
                voice: voice,
                timeSignature: measureTimeSig,
                measureDuration: measureDuration,
                division: division,
            )
            for group in groups {
                // --- Phase 1: collect all note steps for direction ---
                var groupSteps: [Int] = []
                for memberIdx in group.memberIndices {
                    guard let outIdx = voiceChordOutIndex[memberIdx],
                          case let .chord(n, _, _, _, _, _, _, _, _, _, _)
                          = out[outIdx]
                    else { continue }
                    groupSteps.append(contentsOf: n.map(\.step))
                }
                guard groupSteps.count >= 2 else { continue }
                let groupDirection = forcedStem
                    ?? StemDirectionRule.direction(for: groupSteps)
                let stemSideDx: CGFloat = metrics.sp * 0.59
                    * (groupDirection == .up ? 1 : -1)

                // --- Phase 2: per-member anchor info + levels ---
                //
                // All four arrays are length-N (= `group.memberIndices.count`)
                // so a later `enumerated()` over `group.memberIndices` can
                // index them positionally. Members whose chord is missing
                // from `out` (e.g. routed to `invisibleOut` because the
                // chord is fully hidden) get `nil` placeholders in the
                // CGFloat / Int arrays, and `0` in `memberLevels` (a safe
                // placeholder since Phase 5 only emits runs for levels
                // >= 1).
                var memberStemXs: [CGFloat?] = []
                var anchorSteps: [Int?] = []
                var anchorYs: [CGFloat?] = []
                var memberLevels: [Int] = []
                // Beam color is derived from the beamed group's
                // noteheads — MuseScore writes `<Beam><color>` as a
                // standalone sibling element, but in practice it matches
                // the member notes' color. First colored note wins.
                var memberColors: [ScoreColor] = []
                for memberIdx in group.memberIndices {
                    guard let outIdx = voiceChordOutIndex[memberIdx],
                          case let .chord(n, _, _, so, _, _, _, _, _, _, _)
                          = out[outIdx]
                    else {
                        memberStemXs.append(nil)
                        anchorSteps.append(nil)
                        anchorYs.append(nil)
                        memberLevels.append(0)
                        continue
                    }
                    memberColors.append(contentsOf: n.compactMap(\.color))
                    memberStemXs.append(so.x + stemSideDx)
                    let anchorStep: Int
                    let anchorY: CGFloat
                    if groupDirection == .up {
                        anchorStep = n.map(\.step).max() ?? 0
                        anchorY = n.map(\.origin.y).min() ?? so.y
                    } else {
                        anchorStep = n.map(\.step).min() ?? 0
                        anchorY = n.map(\.origin.y).max() ?? so.y
                    }
                    anchorSteps.append(anchorStep)
                    anchorYs.append(anchorY)
                    if case let .chord(c) = voice.elements[memberIdx] {
                        memberLevels.append(beamLevel(c.duration))
                    } else {
                        memberLevels.append(0)
                    }
                }
                let validStemXs = memberStemXs.compactMap(\.self)
                let validAnchorSteps = anchorSteps.compactMap(\.self)
                let validAnchorYs = anchorYs.compactMap(\.self)
                guard validStemXs.count >= 2,
                      let beamStartX = validStemXs.first,
                      let beamEndX = validStemXs.last
                else { continue }

                // --- Phase 3: sloped beam line ---
                let line = computeBeamLine(
                    anchorSteps: validAnchorSteps,
                    anchorYs: validAnchorYs,
                    stemXs: validStemXs,
                    direction: groupDirection,
                    metrics: metrics,
                )
                // Shift the beam line away from the noteheads enough
                // to fit each member's beam stack + tremolo bar block
                // + clearances. Using the group max keeps the beam
                // straight (or slanted as designed) rather than
                // stepping per chord.
                var groupTremoloShift: CGFloat = 0
                for (mIdx, memberIdx) in group.memberIndices.enumerated() {
                    guard case let .chord(c) =
                        voice.elements[memberIdx],
                        let trem = c.tremolo
                    else { continue }
                    let beamH = LayoutEngine.beamStackHeight(
                        beamLevel: memberLevels[mIdx],
                        metrics: metrics,
                    )
                    let barH = LayoutEngine.barBlockHeight(
                        barCount: Int(trem.subtype.rawValue),
                        metrics: metrics,
                    )
                    // beamY → beamStack (beamH) → gap (0.5 sp) →
                    // barBlock (barH) → notehead gap (2 sp from
                    // notehead origin). MuseScore engraves a similar
                    // ~1-1.5 sp visual clearance between the bottom
                    // bar and the notehead glyph; accounting for
                    // Bravura's X / diamond head bboxes (extend
                    // ~0.66 sp above the origin) and the bar's own
                    // slant, 2 sp from the origin is what reproduces
                    // MuseScore's stem length on cymbal tremolos.
                    let required = beamH + metrics.sp * 0.5
                        + barH + metrics.sp * 2.0
                    let ext = max(
                        0, required - metrics.defaultStemLength,
                    )
                    groupTremoloShift = max(groupTremoloShift, ext)
                }
                let beamShift: CGFloat =
                    (groupDirection == .up ? -1 : 1)
                    * groupTremoloShift
                let beamSpan = beamEndX - beamStartX
                func beamYAt(_ x: CGFloat) -> CGFloat {
                    let base: CGFloat
                    if beamSpan > 0 {
                        let t = (x - beamStartX) / beamSpan
                        base = line.startY
                            + (line.endY - line.startY) * t
                    } else {
                        base = line.startY
                    }
                    return base + beamShift
                }
                // Length stays at N; nil where the chord is missing
                // (e.g. fully-invisible chord routed to invisibleOut).
                let memberStemYs: [CGFloat?] = memberStemXs.map { x in
                    x.map(beamYAt)
                }

                // --- Phase 4: rewrite each chord with its own beam y ---
                for (i, memberIdx) in group.memberIndices.enumerated() {
                    guard let outIdx = voiceChordOutIndex[memberIdx],
                          let beamY = memberStemYs[i],
                          case let .chord(
                              n,
                              d,
                              _,
                              so,
                              arp,
                              art,
                              _,
                              vi,
                              _,
                              stemHidden,
                              existingMag,
                          ) = out[outIdx]
                    else { continue }
                    // Beamed chords don't need stem-extension threading
                    // — the renderer reads beamY (= stemOrigin.y) and
                    // ignores stemExtension when isBeamed.
                    out[outIdx] = .chord(
                        notes: n,
                        duration: d,
                        stem: groupDirection,
                        stemOrigin: CGPoint(
                            x: so.x, y: beamY,
                        ),
                        hasArpeggio: arp,
                        arpeggioRawType: art,
                        isBeamed: true,
                        voiceIndex: vi,
                        stemExtension: 0,
                        stemIsInvisible: stemHidden,
                        mag: existingMag,
                    )
                    // Re-anchor any .tremoloBars element belonging to
                    // this chord so its bar block sits past the full
                    // beam stack (primary + secondary beams) for
                    // THIS chord's beam level, replacing the
                    // standalone-midstem estimate emitted before
                    // the beam pass ran.
                    reanchorBeamedTremoloBars(
                        in: &out,
                        afterChordAt: outIdx,
                        beamY: beamY,
                        stem: groupDirection,
                        beamLevel: memberLevels[i],
                        metrics: metrics,
                    )
                    // Re-place this chord's articulations: they were emitted
                    // before the beam fixed the stem direction, so a beamed
                    // chord whose per-chord stem differed from the group could
                    // have its staccato on the wrong side.
                    if case let .chord(modelChord) = voice.elements[memberIdx],
                       !modelChord.articulations.isEmpty
                    {
                        let replacements = Self.articulationElements(
                            for: modelChord.articulations,
                            stem: groupDirection,
                            noteYs: n.map(\.origin.y),
                            chordX: so.x,
                            staffMidY: staffMidY,
                            metrics: metrics,
                        )
                        var j = outIdx + 1
                        var k = 0
                        while j < out.count, k < replacements.count,
                              case let .articulation(_, oldOrigin, _) = out[j],
                              case let .articulation(kind, newOrigin, isAbove)
                              = replacements[k]
                        {
                            // Keep the original X (beaming changes only Y).
                            out[j] = .articulation(
                                kind: kind,
                                origin: CGPoint(x: oldOrigin.x, y: newOrigin.y),
                                isAbove: isAbove,
                            )
                            j += 1
                            k += 1
                        }
                    }
                }

                // --- Phase 5: emit per-level beam runs ---
                //
                // `<Beam><visible>0</visible>` hides the BARS only. The
                // group's stems keep the lengths Phase 4 gave them and
                // still carry no flag glyphs, because the chords remain
                // beamed — MuseScore hides the beam element, it does not
                // unbeam the group. The flag lives on the group's
                // leading chord; see `Chord.beamVisible`.
                let leadIndex = group.memberIndices.first
                let beamIsVisible = leadIndex.map { idx -> Bool in
                    if case let .chord(c) = voice.elements[idx] {
                        return c.beamVisible
                    }
                    return true
                } ?? true
                guard beamIsVisible else { continue }
                let maxLvl = memberLevels.max() ?? 0
                guard maxLvl >= 1 else { continue }
                let beamColor = memberColors.first
                for lvl in 1 ... maxLvl {
                    var runStart: Int?
                    for i in 0 ..< memberLevels.count {
                        let hasThisLevel = memberLevels[i] >= lvl
                        if hasThisLevel && runStart == nil {
                            runStart = i
                        } else if !hasThisLevel, let start = runStart {
                            emitBeamRun(
                                start: start, end: i - 1,
                                level: lvl,
                                memberStemXs: memberStemXs,
                                memberStemYs: memberStemYs,
                                memberCount: memberLevels.count,
                                beamYAt: beamYAt,
                                direction: groupDirection,
                                color: beamColor,
                                metrics: metrics,
                                out: &out,
                            )
                            runStart = nil
                        }
                    }
                    if let start = runStart {
                        emitBeamRun(
                            start: start,
                            end: memberLevels.count - 1,
                            level: lvl,
                            memberStemXs: memberStemXs,
                            memberStemYs: memberStemYs,
                            memberCount: memberLevels.count,
                            beamYAt: beamYAt,
                            direction: groupDirection,
                            color: beamColor,
                            metrics: metrics,
                            out: &out,
                        )
                    }
                }
            }

            // --- Fermata post-beam re-clearance ---
            //
            // The static `voiceChordNorthByTick` / `…SouthByTick`
            // maps used during fermata emission compute each chord's
            // skyline assuming a STANDALONE `defaultStemLength` stem.
            // Beamed chords have a different stem length: the beam Y
            // is set by the GROUP's most extreme anchor (capped by
            // the slope table), so the per-chord stem reaches a
            // beam-driven endpoint that may extend further than the
            // standalone stem — particularly on the lower-anchor
            // members of a stem-up group, or the higher-anchor
            // members of a stem-down group. Recompute each fermata's
            // Y here against the actual post-beam `stemOrigin.y`
            // values now stored in `out`.
            if !fermataPostProcessAnchors.isEmpty {
                var actualStemTipByTick: [Int: CGFloat] = [:]
                for (outIdx, outEl) in out.enumerated() {
                    guard case let .chord(_, _, stemDir, stemOrigin, _, _, _, _, _, _, _) = outEl,
                          let tick = chordTickByOutIndex[outIdx]
                    else { continue }
                    // Per `LayoutEngine+Extents.swift`, the beam pass
                    // writes the BEAM-side stem endpoint into
                    // `stemOrigin.y`: smallest Y for stem-up, largest
                    // Y for stem-down. Combine across multi-voice
                    // shared ticks by taking the more extreme value
                    // in the relevant direction.
                    if let prev = actualStemTipByTick[tick] {
                        actualStemTipByTick[tick] = stemDir == .up
                            ? min(prev, stemOrigin.y)
                            : max(prev, stemOrigin.y)
                    } else {
                        actualStemTipByTick[tick] = stemOrigin.y
                    }
                }
                let fermataDefaultAboveY = staffMidY - metrics.sp * 3
                let fermataDefaultBelowY = staffMidY + metrics.sp * 3
                let visualGap = metrics.sp * 0.5
                for entry in fermataPostProcessAnchors {
                    guard entry.outIndex < out.count,
                          case let .fermata(subtype, oldOrigin) =
                          out[entry.outIndex]
                    else { continue }
                    guard let tick = entry.anchorTick,
                          let stemTip = actualStemTipByTick[tick]
                    else { continue }
                    let newY: CGFloat
                    if entry.isBelow {
                        // glyph TOP = origin.y + topOffset.
                        // Want origin.y + topOffset >= stemTip + gap.
                        let topOffset = FermataGlyphMetrics.below.topOffset
                            * metrics.sp
                        let needed = stemTip + visualGap - topOffset
                        newY = max(fermataDefaultBelowY, max(oldOrigin.y, needed))
                    } else {
                        // glyph BOTTOM = origin.y + bottomOffset.
                        // Want origin.y + bottomOffset <= stemTip - gap.
                        let bottomOffset = FermataGlyphMetrics.above.bottomOffset
                            * metrics.sp
                        let needed = stemTip - visualGap - bottomOffset
                        newY = min(fermataDefaultAboveY, min(oldOrigin.y, needed))
                    }
                    if newY != oldOrigin.y {
                        out[entry.outIndex] = .fermata(
                            subtype: subtype,
                            origin: CGPoint(x: oldOrigin.x, y: newY),
                        )
                    }
                }
            }

            // --- Lyric post-beam re-clearance ---
            //
            // `voiceMaxLyricCenterY` (computed before emission) estimates
            // each chord's south extent from a STANDALONE
            // `defaultStemLength` stem + flag. The beam pass can drive a
            // stem-down endpoint DEEPER than that: `groupDirection` is
            // decided from the group's combined steps, so it can point a
            // member down whose own median pointed up, and that member's
            // stem then reaches the shared beam well below the staff —
            // past the pre-beam lyric row. Lyrics were laid out before
            // beaming, so recompute the row against the actual post-beam
            // stem-down endpoints now stored in `out` and lower the whole
            // voice's lyric row if a beam intrudes. Mirrors the fermata
            // post-beam re-clearance above. It only ever DEEPENS the row:
            // a non-beamed stem-down chord's `stemOrigin.y + stem/flag pad`
            // stays inside the pre-beam estimate (which already added
            // `flagSouthExtent`), so shallow / unbeamed measures — and
            // thus the common case on both iOS and Android — are
            // untouched.
            let voiceHasLyrics = voice.elements.contains { el in
                if case let .chord(chord) = el {
                    return chord.lyrics.contains { !$0.text.isEmpty }
                }
                return false
            }
            if voiceHasLyrics {
                var lowestDownTip = -CGFloat.infinity
                for outIdx in voiceChordOutIndex.values where outIdx < out.count {
                    guard case let .chord(_, _, stemDir, stemOrigin, _, _, _, _, _, _, _)
                        = out[outIdx], stemDir == .down
                    else { continue }
                    lowestDownTip = max(lowestDownTip, stemOrigin.y)
                }
                // Same tight stem/flag pad the pre-beam estimate uses
                // (0.25 sp `lyricsMinDistance` + 1.1 sp lyric ascender).
                let requiredCenterY = lowestDownTip + metrics.sp * (0.25 + 1.1)
                if lowestDownTip.isFinite, requiredCenterY > voiceMaxLyricCenterY {
                    let dy = requiredCenterY - voiceMaxLyricCenterY
                    out = out.map { shiftLyricTextY($0, dy: dy) }
                }
            }

            // --- Tuplet brackets / numbers ---
            //
            // For each tuplet span in the voice, determine whether every
            // member sits inside a single beam group (in which case
            // MuseScore drops the bracket and shows just the number
            // above/below the beam). Otherwise draw a square bracket
            // with hooks.
            for tuplet in voice.tuplets {
                guard tuplet.startIndex >= 0,
                      tuplet.endIndex < voice.elements.count,
                      tuplet.startIndex <= tuplet.endIndex
                else { continue }
                emitTupletLabel(
                    tuplet: tuplet,
                    voice: voice,
                    voiceChordOutIndex: voiceChordOutIndex,
                    voiceRestOutIndex: voiceRestOutIndex,
                    out: &out,
                    beamGroups: beamGroups(
                        voice: voice,
                        timeSignature: measureTimeSig,
                        measureDuration: measureDuration,
                        division: division,
                    ),
                    staffMidY: staffMidY,
                    metrics: metrics,
                    tupletID: TupletID(
                        staff: staffAddress,
                        measureIndex: measureIndex,
                        voiceIndex: voiceIdx,
                        startElementIndex: tuplet.startIndex,
                    ),
                )
            }
        }

        // Trailing bar line if no voice emitted one.
        // The final measure of the score gets a "end" barline
        // (thin + thick) per standard engraving convention.
        //
        // Slot-preservation note: a hidden explicit bar in the voice
        // is routed to `invisibleOut`, so we must check BOTH lists —
        // otherwise we'd synth an implicit (visible) bar on top of
        // the hidden one, defeating the visibility toggle.
        let hasExplicitBar = (out + invisibleOut).contains {
            if case .barLine = $0 { true } else { false }
        }
        if !hasExplicitBar {
            out.append(.barLine(
                subtype: isLastMeasure ? "end" : nil,
                origin: CGPoint(
                    x: width - metrics.sp / 2,
                    y: staffMidY,
                ),
            ))
        }
        for continuation in incomingMelismas {
            emitMelismaContinuation(
                continuation: continuation,
                staffMidY: staffMidY,
                tickColumns: tickColumns,
                headerContentStartX: headerSchedule.contentStartX,
                measureWidth: width,
                metrics: metrics,
                out: &out,
            )
        }
        // Inject system-level elements (tempo / rehearsal mark /
        // system or staff text / swing) lifted to score level. Each
        // element renders at the X column matching its
        // MeasurePosition tick, with the same Y conventions the
        // previous voice-element-based path used. RehearsalMark is
        // anchored at measure-left (matches MuseScore's default
        // placement at the start of the bar).
        for positioned in systemElements {
            let tick = positioned.position.ticks(division: division)
            let xAtTick = tickColumns[tick]
                ?? headerSchedule.contentStartX
            switch positioned.element {
            case let .tempo(t):
                guard t.visible || options.showsInvisibleElements else { break }
                let value = Int(t.beatsPerMinute.rounded())
                // `t.beatGlyph` is the marking's beat note as Bravura "Individual notes" glyphs (e.g. a quarter
                // U+E1D5, or a dotted quarter U+E1D5 U+E1E7). Renderers split the string into Bravura-glyph and
                // Edwin-text runs via `MusicTextRuns.runs`.
                let element = LayoutElement.textMark(
                    kind: .tempo,
                    text: "\(t.beatGlyph) = \(value)",
                    origin: CGPoint(
                        x: xAtTick
                            + CGFloat(t.offsetX) * metrics.sp,
                        y: staffMidY - metrics.sp * 4
                            + CGFloat(t.offsetY) * metrics.sp,
                    ),
                )
                if t.visible { out.append(element) } else { invisibleOut.append(element) }
            case let .staffText(st):
                guard st.visible || options.showsInvisibleElements else { break }
                let element = LayoutElement.staffText(
                    text: st.text,
                    origin: CGPoint(
                        x: xAtTick
                            + CGFloat(st.offsetX) * metrics.sp,
                        y: staffMidY - metrics.sp * 3
                            + CGFloat(st.offsetY) * metrics.sp,
                    ),
                    color: st.color,
                    isSystemText: st.isSystemText,
                )
                if st.visible { out.append(element) } else { invisibleOut.append(element) }
            case let .swing(s):
                guard s.visible || options.showsInvisibleElements else { break }
                let element = LayoutElement.staffText(
                    text: s.text,
                    origin: CGPoint(
                        x: xAtTick
                            + CGFloat(s.offsetX) * metrics.sp,
                        y: staffMidY - metrics.sp * 3
                            + CGFloat(s.offsetY) * metrics.sp,
                    ),
                    color: s.color,
                    isSystemText: s.isSystemText,
                )
                if s.visible { out.append(element) } else { invisibleOut.append(element) }
            case let .rehearsalMark(rm):
                guard rm.visible || options.showsInvisibleElements else { break }
                let originX = metrics.sp * 0.5
                let rehearsalElement = LayoutElement.rehearsalMark(
                    text: rm.text,
                    origin: CGPoint(
                        x: originX
                            + CGFloat(rm.offsetX) * metrics.sp,
                        y: staffMidY - metrics.sp * 3.5
                            + CGFloat(rm.offsetY) * metrics.sp,
                    ),
                    frame: rm.frame,
                    color: rm.color,
                )
                if rm.visible {
                    out.append(rehearsalElement)
                } else {
                    invisibleOut.append(rehearsalElement)
                }
            }
        }
        return (out, invisibleOut, currentClef, currentKey)
    }

    /// Decide which notes in a chord need to render on the OPPOSITE
    /// side of the stem from the chord's natural side. Mirrors
    /// MuseScore's `ChordLayout::layoutChords2`: walk notes in
    /// step-sorted order (bottom-up for stem-up, top-down for
    /// stem-down) and flip the side whenever an adjacent pair sits
    /// less than 2 staff lines apart (a "second" or unison). Stays
    /// flipped through a cluster of consecutive seconds and returns
    /// to the default side once the gap reopens.
    static func applyChordMirroring(
        _ notes: [LayoutChordNote],
        stem: StemDirection,
    ) -> [LayoutChordNote] {
        guard notes.count >= 2 else { return notes }
        let isUp = stem == .up
        let order: [Int] = (0 ..< notes.count).sorted { i, j in
            isUp ? notes[i].step < notes[j].step
                : notes[i].step > notes[j].step
        }
        var mirrors = [Bool](repeating: false, count: notes.count)
        // `isLeft` tracks which side of the stem the current note
        // sits on. Default = the chord's natural side: left for
        // stem-up, right for stem-down. (MuseScore initializes
        // `isLeft = chord.up()` for the same reason.) `prevLine`
        // starts huge so the first iteration never registers a
        // conflict.
        var isLeft = isUp
        var prevLine = 1000
        for idx in order {
            let line = notes[idx].step
            let conflict = abs(prevLine - line) < 2
            if conflict || (isUp != isLeft) {
                isLeft.toggle()
            }
            mirrors[idx] = isUp != isLeft
            prevLine = line
        }
        return notes.enumerated().map { i, n in
            LayoutChordNote(
                noteID: n.noteID,
                step: n.step,
                accidental: n.accidental,
                origin: n.origin,
                tieForward: n.tieForward,
                tieBack: n.tieBack,
                hasGlissando: n.hasGlissando,
                headType: n.headType,
                mirror: mirrors[i],
                isInvisible: n.isInvisible,
                color: n.color,
                accidentalBracket: n.accidentalBracket,
                parentheses: n.parentheses,
            )
        }
    }

    /// Build `LayoutChordNote` values for a single `GraceChord`.
    /// Mirrors the inline notehead construction used for main chords
    /// but takes `graceIdx` / `isAfter` so synthesized `NoteID`s
    /// don't collide with the parent chord's notes — important for
    /// hit-testing and the chord-origin lookup.
    fileprivate static func makeGraceLayoutNotes( // swiftlint:disable:this function_parameter_count
        grace: GraceChord,
        atX x: CGFloat,
        staffMidY: CGFloat,
        metrics: StaffMetrics,
        currentClef: NotatedClef,
        staffAddress: StaffAddress,
        measureIndex: Int,
        voiceIdx: Int,
        voiceElemIdx: Int,
        graceIdx: Int,
        isAfter: Bool,
        drumLineMap: [Int: Int]?,
        showsInvisibleElements: Bool = false,
    ) -> [LayoutChordNote] {
        // Grace NoteIDs reuse the parent's element index but encode
        // the grace position in `noteIndexInChord` so they stay
        // unique across the (parent, grace) cluster:
        //   before-grace #i  → 1000 + i*100 + noteIdx
        //   after-grace  #i  → 2000 + i*100 + noteIdx
        // Cap at 8 graces × 16 notes per grace — well above
        // anything seen in real scores.
        let base = (isAfter ? 2000 : 1000) + graceIdx * 100
        return grace.notes.enumerated().map { noteIdx, note in
            let step: Int
            if let drumLine = drumLineMap?[note.pitch] {
                step = 4 - drumLine
            } else {
                step = PitchStaffPosition.step(
                    midiPitch: note.pitch, tpc: note.tpc,
                    clef: currentClef,
                ).step
            }
            let y = staffMidY - CGFloat(step) * metrics.sp / 2
            let id = NoteID(
                staff: staffAddress,
                measureIndex: measureIndex,
                voiceIndex: voiceIdx,
                elementIndex: voiceElemIdx,
                noteIndexInChord: base + noteIdx,
            )
            return LayoutChordNote(
                noteID: id,
                step: step,
                accidental: note.accidental,
                origin: CGPoint(x: x, y: y),
                tieForward: nil, tieBack: nil,
                hasGlissando: false,
                headType: note.headType,
                // Pure "source hidden" flag — renderers consult
                // `LayoutSystem.showsInvisibleElements` to decide
                // whether to gray or skip per-note.
                isInvisible: !note.visible,
                color: note.elementProperties.color,
                accidentalBracket: note.accidentalBracket,
                parentheses: note.parentheses,
            )
        }
    }

    /// Verse-0 lyric baseline floor before any chord-driven push. Sits
    /// 2 sp below the staff by default; when a visible below-staff
    /// spanner (hairpin, pedal, ...) covers this measure, drop another
    /// ~3 sp so the spanner's glyph fits between staff and lyric.
    /// `staffBottom = staffMidY + 2 sp`; hairpin centerline rests at
    /// `staffBottom + 3 sp`, ink reaches `staffBottom + 4 sp`. Lyric
    /// baseline 1.4 sp under that leaves room for cap-height + a
    /// small visual gap.
    /// Conservative below-stem-end extent of an isolated short
    /// note's flag glyph, in points. Bravura's flag glyphs grow by
    /// ~0.5 sp per added flag tab; values here cap at 64th to match
    /// what the renderer can draw via `StemRenderer.flagGlyph`. For
    /// beamed chords the actual extent is the beam Y (computed in a
    /// later pass) — using the unbeamed flag estimate here is a
    /// safe over-allocation that keeps lyrics clear in either case.
    static func flagSouthExtent(
        duration: NoteDuration, metrics: StaffMetrics,
    ) -> CGFloat {
        switch duration {
        case .eighth: metrics.sp * 1.5
        case .sixteenth: metrics.sp * 2.0
        case .thirtySecond: metrics.sp * 2.5
        case .sixtyFourth: metrics.sp * 3.0
        default: 0
        }
    }

    /// Lowest lyric-center Y a chord forces, taking the max of
    /// the per-obstacle clearances. Returns `nil` for empty chords.
    ///
    /// Two clearance regimes match MuseScore's south-skyline plus
    /// `Sid::lyricsMinDistance` semantics (default 0.25 sp;
    /// `styledef.cpp:78`):
    ///
    /// * **Notehead** — uses the historical 2.1 sp pad so a low-
    ///   pitched chord (notehead well below the staff) still gets a
    ///   generous lyric gap matching the existing visual.
    /// * **Stem / flag** — uses a tighter 1.35 sp pad (= 0.25 sp
    ///   minDistance + 1.1 sp lyric ascender). Stems and flags are
    ///   thin obstacles; pushing the lyric a full 2.1 sp below them
    ///   over-spaces visibly when the protrusion is small.
    /// * **Stem-up + tie** — same notehead pad applied to a slightly
    ///   lowered south so the tie arc clears.
    private static func chordLyricAvoidY(
        chord: Chord,
        forcedStem: StemDirection?,
        currentClef: NotatedClef,
        drumLineMap: [Int: Int]?,
        staffMidY: CGFloat,
        metrics: StaffMetrics,
    ) -> CGFloat? {
        let steps: [Int] = chord.notes.map { note in
            if let drumLine = drumLineMap?[note.pitch] {
                return 4 - drumLine
            }
            return PitchStaffPosition.step(
                midiPitch: note.pitch, tpc: note.tpc,
                clef: currentClef,
            ).step
        }
        let stemDir = forcedStem
            ?? StemDirectionRule.direction(for: steps)
        guard let lowestStep = steps.min() else { return nil }
        let lowestNoteY = staffMidY
            - CGFloat(lowestStep) * metrics.sp / 2
        let noteheadBottom = lowestNoteY + metrics.sp * 0.5
        let noteheadPad = metrics.sp * (1 + 1.1)
        let stemFlagPad = metrics.sp * (0.25 + 1.1)

        var avoidY = noteheadBottom + noteheadPad
        // Stem-down: stem extends to `lowestNoteY +
        // defaultStemLength` (StemRenderer:47); flag glyph hangs
        // further. Mirrors MuseScore's south-skyline contribution
        // from `Stem` + `Hook` (lyricslayout.cpp:662).
        if stemDir == .down {
            let stemEnd = lowestNoteY + metrics.defaultStemLength
            let stemSouth = stemEnd + flagSouthExtent(
                duration: chord.duration, metrics: metrics,
            )
            avoidY = max(avoidY, stemSouth + stemFlagPad)
        }
        // Stem-up + tied: tie arc curls below the lowest notehead;
        // 0.8 sp keeps it clear of the lyric row.
        if stemDir == .up {
            let hasTie = chord.notes.contains {
                $0.tieForward != nil || $0.tieBack != nil
            }
            if hasTie {
                let tieSouth = noteheadBottom + metrics.sp * 0.8
                avoidY = max(avoidY, tieSouth + noteheadPad)
            }
        }
        return avoidY
    }

    private static func lyricBaseFloor(
        staffMidY: CGFloat,
        metrics: StaffMetrics,
        coversBelowStaffSpanner: Bool,
    ) -> CGFloat {
        let base = staffMidY + metrics.sp * 4
        if coversBelowStaffSpanner {
            return max(base, staffMidY + metrics.sp * 7.4)
        }
        return base
    }

    /// Map a `ChordArticulation.Kind` to the renderable layout-local
    /// kind, returning `nil` for `.unknown(_)` so callers skip emission.
    static func renderableArticulationKind(
        _ kind: ChordArticulation.Kind,
    ) -> LayoutElement.ArticulationKind? {
        switch kind {
        case .staccato: .staccato
        case .staccatissimo: .staccatissimo
        case .tenuto: .tenuto
        case .accent: .accent
        case .marcato: .marcato
        case .accentStaccato: .accentStaccato
        case .marcatoStaccato: .marcatoStaccato
        case .unknown: nil
        }
    }

    /// Whether the articulation is placed close to the notehead (it may stay
    /// inside the staff) rather than pushed clear of the staff.
    ///
    /// Mirrors MuseScore's `Articulation::layoutCloseToNote()`: the single
    /// staccato dot, staccatissimo wedge, and tenuto line hug the note; accent,
    /// marcato, and the combined forms sit outside the staff.
    static func articulationHugsNote(
        _ kind: LayoutElement.ArticulationKind,
    ) -> Bool {
        switch kind {
        case .staccato, .staccatissimo, .tenuto: true
        case .accent, .marcato, .accentStaccato, .marcatoStaccato: false
        }
    }

    /// Marcato-family glyphs that always sit above the staff regardless of
    /// stem direction (Gould p.117 — "strong accents above the staff"),
    /// mirroring MuseScore's `Chord::layoutArticulations` special case for
    /// `articMarcato…` SymIds.
    static func articulationForcesAbove(
        _ kind: LayoutElement.ArticulationKind,
    ) -> Bool {
        switch kind {
        case .marcato, .marcatoStaccato: true
        case .staccato, .staccatissimo, .tenuto, .accent, .accentStaccato: false
        }
    }

    /// Build the `.articulation` layout elements for one chord, mirroring
    /// MuseScore's `Chord::layoutArticulations` (libmscore/chord.cpp).
    ///
    /// Round-trip-only `.unknown` kinds are filtered.
    ///
    /// Side: the stored SymId `…Above`/`…Below` suffix is glyph orientation
    /// only. For the default (CHORD) anchor MuseScore recomputes the side from
    /// stem direction on load — away from the stem, on the notehead side — so
    /// `art.anchor` is deliberately not consulted. Marcato-family glyphs always
    /// sit above. Because beaming can flip a chord's stem after the first
    /// placement pass, the beam pass re-invokes this with the group direction.
    ///
    /// Distance, close-to-note glyphs (staccato / staccatissimo / tenuto):
    /// staff-line aware — 1 sp into a space, 1.5 sp when the note is on a staff
    /// line, and 1 sp once the note reaches the outer staff line or beyond. The
    /// reference Y is then shifted by the glyph's ink-center offset so the
    /// rendered dot lands exactly there (see `ArticulationGlyphMetrics`). Other
    /// glyphs (accent / marcato / combinations) are pushed clear of the staff.
    /// Stacking adds 1 sp per extra glyph on a side.
    static func articulationElements(
        for articulations: [ChordArticulation],
        stem: StemDirection,
        noteYs: [CGFloat],
        chordX: CGFloat,
        staffMidY: CGFloat,
        metrics: StaffMetrics,
    ) -> [LayoutElement] {
        let staffTopY = staffMidY - metrics.sp * 2
        let staffBottomY = staffMidY + metrics.sp * 2
        let topLineY = staffMidY - metrics.sp * 2
        let lastStaffLine = 8 // (5 staff lines − 1) × 2, in half-spaces
        var aboveCount = 0
        var belowCount = 0
        var result: [LayoutElement] = []
        for art in articulations {
            guard let artKind = renderableArticulationKind(art.kind)
            else { continue }
            let isAbove = articulationForcesAbove(artKind)
                ? true
                : (stem == .down)
            let positioned: CGFloat
            if articulationHugsNote(artKind) {
                // `line` is MuseScore's half-space index from the top staff
                // line (lines even, spaces odd); higher line == lower.
                let refY = isAbove
                    ? (noteYs.min() ?? staffMidY)
                    : (noteYs.max() ?? staffMidY)
                let line = Int(((refY - topLineY) * 2 / metrics.sp).rounded())
                let halfSpaces: Int
                if isAbove {
                    halfSpaces = line > 0 ? ((line + 1) & ~1) - 3 : line - 2
                } else {
                    halfSpaces = line < lastStaffLine ? (line & ~1) + 3 : line + 2
                }
                let reference = topLineY + CGFloat(halfSpaces) * 0.5 * metrics.sp
                let cp = UInt16(truncatingIfNeeded: ArticulationGlyph.codepoint(
                    kind: artKind, isAbove: isAbove,
                ))
                let inkOffset = ArticulationGlyphMetrics.inkCenterOffset(
                    codepoint: cp,
                )
                positioned = reference - inkOffset * metrics.sp
            } else if isAbove {
                let baseY = (noteYs.min() ?? staffMidY) - metrics.sp * 0.5
                positioned = min(baseY, staffTopY - metrics.sp * 0.5)
            } else {
                let baseY = (noteYs.max() ?? staffMidY) + metrics.sp * 0.5
                positioned = max(baseY, staffBottomY + metrics.sp * 0.5)
            }
            let stackUnits = isAbove ? aboveCount : belowCount
            let stackOffset = metrics.sp * CGFloat(stackUnits)
            let y = positioned + (isAbove ? -stackOffset : stackOffset)
            result.append(.articulation(
                kind: artKind,
                origin: CGPoint(x: chordX, y: y),
                isAbove: isAbove,
            ))
            if isAbove { aboveCount += 1 } else { belowCount += 1 }
        }
        return result
    }
}
