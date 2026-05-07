// swiftlint:disable function_body_length file_length
import CoreGraphics
import CoreText
import SheetMusicCore

/// A melisma that extends INTO a measure from an earlier measure.
/// The anchor measure (where the `<Lyrics>` element lives) is
/// handled inside `emitMelismaLine`; instances of this type describe
/// the left-hand continuation rule drawn on the following measures.
@available(macOS 15.0, iOS 16.0, *)
struct MelismaContinuation: Sendable, Equatable {
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
@available(macOS 15.0, iOS 16.0, *)
struct MelismaLyricKey: Hashable, Sendable {
    let staffIndex: Int
    let measureIndex: Int
    let voiceIndex: Int
    let elementIndex: Int
    let verseIndex: Int
}

@available(macOS 15.0, iOS 16.0, *)
extension LayoutEngine {
    /// Place elements of a measure in local measure coordinates.
    /// Returns the placed elements + the updated clef context.
    ///
    /// Layout strategy: non-timed leading elements (clef / key sig / time
    /// sig) are stacked left-to-right at fixed widths. Timed elements
    /// (chords and rests) are then positioned proportionally to their
    /// tick offset within the measure so the content fills the full
    /// stretched measure width.
    static func placeMeasureElements(
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
        drumLineMap: [Int: Int]? = nil,
        isLastMeasure: Bool = false,
        incomingMelismas: [MelismaContinuation] = [],
        effectiveMelismaTicks: [MelismaLyricKey: Int] = [:]
    ) -> (elements: [LayoutElement], clef: NotatedClef, key: Int) {
        let staffMidY = metrics.staffHeight / 2 + metrics.sp * 2
        var out: [LayoutElement] = []
        var currentClef = activeClef
        var currentKey = activeKey

        // --- Scan: time signature and total ticks in the widest voice ---
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
        let voicesWithChords = measure.voices.filter { v in
            v.elements.contains {
                if case let .chord(c) = $0, !c.notes.isEmpty {
                    return true
                }
                return false
            }
        }.count
        let voicesWithContent = measure.voices.filter { v in
            v.elements.contains {
                if case .chord = $0 { return true }
                return false
            }
        }.count
        let hasMultiChordVoices = voicesWithChords > 1
        let hasMultiContentVoices = voicesWithContent > 1
        let isMultiVoice = hasMultiChordVoices

        var remainingSynthClef = synthesizeLeadingClef
        var remainingSynthKeySig = synthesizeLeadingKeySig
        for (voiceIdx, voice) in measure.voices.enumerated() {
            var tickCursor = 0
            var inHeader = true
            var voiceChordOutIndex: [Int: Int] = [:]
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
                    return acc + c.duration.ticks(division: division)
                default:
                    return acc
                }
            }

            // Forced stem direction for multi-voice measures.
            let forcedStem: StemDirection? = isMultiVoice
                ? (voiceIdx.isMultiple(of: 2) ? .up : .down)
                : nil
            // Rest y offset when multiple voices coexist — even if the
            // second voice only carries rests, we still need to pull
            // them out of the way of voice 0's melody.
            let restVoiceOffset: CGFloat = hasMultiContentVoices
                ? (voiceIdx.isMultiple(of: 2)
                    ? -metrics.sp * 2
                    : metrics.sp * 2)
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
                    let ticks = chord.duration.ticks(division: division)
                    defer { t += ticks }
                    guard !chord.notes.isEmpty else { continue }
                    let steps: [Int] = chord.notes.map { note in
                        if let drumLine = drumLineMap?[note.pitch] {
                            return 4 - drumLine
                        }
                        return PitchStaffPosition.step(
                            midiPitch: note.pitch, tpc: note.tpc,
                            clef: currentClef
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
                    // the HIGHEST note's centre, mirroring
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

            // Final lyric centre Y for this voice — the max over
            // all chords' south-skyline-pushed Ys. Pre-computed
            // here (rather than ratcheted incrementally during
            // emission) so every chord's lyric uses the SAME Y;
            // otherwise earlier chords sit at a lower ratchet
            // value than later ones and the in-measure lyric row
            // is jagged.
            let voiceMaxLyricCenterY: CGFloat = {
                var maxY = staffMidY + metrics.sp * 4
                for el in voice.elements {
                    guard case let .chord(chord) = el else { continue }
                    let steps: [Int] = chord.notes.map { note in
                        if let drumLine = drumLineMap?[note.pitch] {
                            return 4 - drumLine
                        }
                        return PitchStaffPosition.step(
                            midiPitch: note.pitch, tpc: note.tpc,
                            clef: currentClef
                        ).step
                    }
                    let stemDir = forcedStem
                        ?? StemDirectionRule.direction(for: steps)
                    guard let lowestStep = steps.min()
                    else { continue }
                    let lowestNoteY = staffMidY
                        - CGFloat(lowestStep) * metrics.sp / 2
                    let noteheadBottom = lowestNoteY
                        + metrics.sp * 0.5
                    var south = noteheadBottom
                    if stemDir == .up {
                        let hasTie = chord.notes.contains {
                            $0.tieForward != nil
                                || $0.tieBack != nil
                        }
                        if hasTie {
                            south = max(
                                south,
                                noteheadBottom + metrics.sp * 0.8
                            )
                        }
                    }
                    let southAvoidY = south
                        + metrics.sp * (1 + 1.1)
                    maxY = max(maxY, southAvoidY)
                }
                return maxY
            }()

            // Emit the synthesized leading clef exactly once, at the top
            // of the first voice to process it.
            if remainingSynthClef, let rawType = initialClefRawType {
                out.append(.clef(
                    rawType: rawType,
                    origin: CGPoint(
                        x: headerSchedule.clefX, y: staffMidY
                    )
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
                        x: headerSchedule.keySigX, y: staffMidY
                    )
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

            for (voiceElemIdx, el) in voice.elements.enumerated() {
                switch el {
                case let .clef(clef):
                    currentClef = NotatedClef(rawType: clef.concertClefType)
                    let clefX = inHeader ? headerSchedule.clefX
                        : timedX(atTick: tickCursor)
                    out.append(.clef(
                        rawType: clef.concertClefType,
                        origin: CGPoint(x: clefX, y: staffMidY)
                    ))
                case let .keySignature(key):
                    currentKey = key.concertKey
                    let keyX = inHeader ? headerSchedule.keySigX : timedX(atTick: tickCursor)
                    out.append(.keySignature(
                        sharps: max(0, key.concertKey),
                        flats: max(0, -key.concertKey),
                        origin: CGPoint(x: keyX, y: staffMidY)
                    ))
                case let .timeSignature(ts):
                    let tsX = inHeader ? headerSchedule.timeSigX : timedX(atTick: tickCursor)
                    out.append(.timeSignature(
                        numerator: ts.numerator,
                        denominator: ts.denominator,
                        origin: CGPoint(x: tsX, y: staffMidY)
                    ))
                case let .barLine(b):
                    let barX = inHeader ? metrics.sp : timedX(atTick: tickCursor)
                    out.append(.barLine(
                        subtype: b.subtype,
                        origin: CGPoint(x: barX, y: staffMidY)
                    ))
                case let .chord(r) where r.notes.isEmpty:
                    inHeader = false
                    let (restBase, _) = DurationInterpretation.split(
                        r.duration)
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
                    // Whole-measure rest: ALWAYS centered horizontally
                    // in the measure body, even when other voices
                    // carry content — that's how MuseScore engraves
                    // it (`Rest::layout` falls into the
                    // `centerInMeasure` branch whenever the rest's
                    // duration spans the full measure, irrespective
                    // of voice multiplicity). The vertical offset
                    // assigned by `restVoiceOffset` keeps voice 2 /
                    // 3 / 4 rests off voice 1's melody line, so
                    // centering doesn't introduce any actual
                    // collision.
                    let isWholeRest = restBase == .whole
                    let restX: CGFloat
                    if isWholeRest {
                        // Centre the rest in the measure's chord
                        // area: midpoint of [contentStart,
                        // width − trailingPadding]. Must track
                        // `minimumMeasureWidth.rightPadding` and
                        // `chordSpacingTickToX.trailingGap` —
                        // otherwise the rest drifts off-centre
                        // whenever those constants are tuned.
                        let trailingPad = metrics.sp * 1
                        restX = (headerSchedule.contentStartX
                            + width - trailingPad) / 2
                    } else {
                        restX = timedX(atTick: tickCursor)
                    }
                    let restID = RestID(
                        staff: staffAddress,
                        measureIndex: measureIndex,
                        voiceIndex: voiceIdx,
                        elementIndex: voiceElemIdx
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
                    let needsLeger = (restBase == .whole
                        || restBase == .half)
                        && (restY < staffTopLocal
                            || restY > staffBottomLocal)
                    voiceRestOutIndex[voiceElemIdx] = out.count
                    out.append(.rest(
                        duration: r.duration,
                        origin: CGPoint(x: restX, y: restY),
                        voiceIndex: voiceIdx,
                        restID: restID,
                        hasLegerLine: needsLeger
                    ))
                    tickCursor += r.duration.ticks(division: division)
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
                                clef: currentClef
                            ).step
                        }
                        let y = staffMidY - CGFloat(step) * metrics.sp / 2
                        let id = NoteID(
                            staff: staffAddress,
                            measureIndex: measureIndex,
                            voiceIndex: voiceIdx,
                            elementIndex: voiceElemIdx,
                            noteIndexInChord: noteIdx
                        )
                        return LayoutChordNote(
                            noteID: id,
                            step: step,
                            accidental: note.accidental,
                            origin: CGPoint(x: chordX, y: y),
                            tieForward: note.tieForward,
                            tieBack: note.tieBack,
                            hasGlissando: note.glissando != nil,
                            headType: note.headType
                        )
                    }
                    let stem = forcedStem
                        ?? StemDirectionRule.direction(
                            for: preliminaryNotes.map(\.step))
                    let chordNotes = applyChordMirroring(
                        preliminaryNotes, stem: stem
                    )
                    let mainElement: LayoutElement = .chord(
                        notes: chordNotes,
                        duration: chord.duration,
                        stem: stem,
                        stemOrigin: CGPoint(x: chordX, y: staffMidY),
                        hasArpeggio: chord.arpeggio != nil,
                        arpeggioRawType: chord.arpeggio.flatMap(arpeggioSubtype),
                        isBeamed: false,
                        voiceIndex: voiceIdx
                    )
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
                            drumLineMap: drumLineMap
                        )
                        let graceStem = StemDirectionRule.direction(
                            for: layoutNotes.map(\.step)
                        )
                        out.append(.graceChord(
                            notes: layoutNotes,
                            duration: g.duration,
                            stem: graceStem,
                            stemOrigin: CGPoint(x: chordX + relX, y: staffMidY),
                            relativeX: relX,
                            hasSlash: g.graceType == .acciaccatura,
                            mag: mag,
                            voiceIndex: voiceIdx
                        ))
                    }
                    voiceChordOutIndex[voiceElemIdx] = out.count
                    out.append(mainElement)
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
                            drumLineMap: drumLineMap
                        )
                        let graceStem = StemDirectionRule.direction(
                            for: layoutNotes.map(\.step)
                        )
                        out.append(.graceChord(
                            notes: layoutNotes,
                            duration: g.duration,
                            stem: graceStem,
                            stemOrigin: CGPoint(x: chordX + relX, y: staffMidY),
                            relativeX: relX,
                            hasSlash: false,
                            mag: mag,
                            voiceIndex: voiceIdx
                        ))
                    }
                    if let arp = chord.arpeggio {
                        let ys = chordNotes.map(\.origin.y)
                        let top = ys.min() ?? staffMidY
                        let bot = ys.max() ?? staffMidY
                        out.append(.arpeggioWiggle(
                            top: CGPoint(x: chordX, y: top),
                            bottom: CGPoint(x: chordX, y: bot),
                            subtype: arpeggioSubtype(arp)
                        ))
                    }
                    // Lyrics: emit the syllable text + (if the lyric
                    // extends beyond this chord) a melisma rule that
                    // stretches to the end of the last note it covers.
                    let chordTicks = chord.duration.ticks(
                        division: division)
                    // Use the voice's pre-computed max south-driven
                    // Y so every chord in the measure shares the
                    // same lyric centre (within-measure horizontal
                    // alignment). The system-wide post-pass in
                    // `LayoutEngine.layout` then aligns this Y
                    // across measures of the same system.
                    let chordLyricCenterY = voiceMaxLyricCenterY
                    for (verseIdx, lyric) in chord.lyrics.enumerated() {
                        guard !lyric.text.isEmpty else { continue }
                        // Verse stride 1.7 sp keeps multi-verse
                        // stacks compact while still clearing
                        // ascender/descender overlap between
                        // adjacent verse lines (≈
                        // `Sid::lyricsLineHeight = 1.0` × font
                        // height).
                        let lyricsY = chordLyricCenterY
                            + CGFloat(verseIdx) * metrics.sp * 1.7
                        out.append(.textMark(
                            kind: .lyrics,
                            text: lyric.text,
                            origin: CGPoint(x: chordX, y: lyricsY)
                        ))
                        let textWidth = Self.lyricsTextWidth(
                            lyric.text, sp: metrics.sp
                        )
                        // Hyphens between this syllable and the
                        // previous one in the same verse.
                        if let prev = previousLyric[verseIdx],
                           connectsWithHyphen(
                               prev: prev.syllabic,
                               curr: lyric.syllabic
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
                                out: &out
                            )
                        }
                        previousLyric[verseIdx] = LyricTrail(
                            centerX: chordX,
                            textWidth: textWidth,
                            lyricsY: lyricsY,
                            syllabic: lyric.syllabic
                        )
                        // `<ticks>N</ticks>` in MuseScore marks a
                        // melisma whose visual rule reaches the
                        // chord that starts at `anchor.tick + N`.
                        // Any positive value means "draw a melisma
                        // line up to that target chord" — even when
                        // it equals the anchor chord's own duration
                        // (in which case the target is whatever
                        // chord follows the anchor).
                        if lyric.ticks > 0 {
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
                                out: &out
                            )
                        }
                    }
                    tickCursor += chordTicks
                case let .dynamic(d):
                    // Dynamics sit below-left of the note they apply to
                    // (i.e. the next timed element at the current tick).
                    // Shift 1 sp left so the label doesn't overlap the
                    // following chord's notehead or stem.
                    let baseX = inHeader
                        ? headerSchedule.contentStartX
                        : timedX(atTick: tickCursor)
                    // Default Y: 4 sp below the staff midline (= 2 sp
                    // below the bottom staff line). When the anchor
                    // chord at the same tick extends below the staff
                    // (low ledger lines, stem-down low chord), push
                    // the Y down so the SMuFL glyph clears the chord
                    // skyline. Anchor `.leading` puts the glyph centre
                    // at `origin.y` and the glyph height is ~4 sp, so
                    // a centre Y of `chordSouth + 2.5 sp` leaves
                    // ~0.5 sp of clearance above the glyph top —
                    // matching MuseScore's `Sid::dynamicsMinDistance`.
                    let defaultDynY = staffMidY + metrics.sp * 4
                    let chordSouth = voiceChordSouthByTick[tickCursor]
                        ?? -.infinity
                    let chordAvoid = chordSouth + metrics.sp * 2.5
                    let dynY = max(defaultDynY, chordAvoid)
                    out.append(.textMark(
                        kind: .dynamic,
                        text: d.subtype,
                        origin: CGPoint(
                            x: baseX - metrics.sp,
                            y: dynY
                        )
                    ))
                case let .staffText(st):
                    // Hidden text contributes neither glyphs nor
                    // vertical extent — drop before any layout
                    // measurement so collision avoidance ignores it.
                    if !st.visible { break }
                    // Place at the current tick column (or header
                    // start if we haven't reached any timed element
                    // yet). Default Y is `sp * 3` above the top
                    // staff line (matches MuseScore's
                    // `staffTextPlacement` default of "above" with
                    // an offset just clear of the staff). The
                    // author's `<offset>` (in spatium units) shifts
                    // both axes from there.
                    let stX = inHeader
                        ? headerSchedule.contentStartX
                        : timedX(atTick: tickCursor)
                    out.append(.staffText(
                        text: st.text,
                        origin: CGPoint(
                            x: stX + CGFloat(st.offsetX) * metrics.sp,
                            y: staffMidY - metrics.sp * 3
                                + CGFloat(st.offsetY) * metrics.sp
                        ),
                        color: st.color,
                        isSystemText: st.isSystemText
                    ))
                case let .tempo(t):
                    // Hidden tempo still drives playback (see MIDI
                    // renderer) but contributes no glyph or
                    // vertical extent here.
                    if !t.visible { break }
                    let bpm = Int((t.beatsPerSecond * 60.0).rounded())
                    // "♩" is Unicode U+2669, rendered in the system text font,
                    // not a SMuFL/Bravura glyph — do not migrate to a SMuFL
                    // codepoint without also switching the renderer's font.
                    let tempoX = inHeader
                        ? headerSchedule.contentStartX
                        : timedX(atTick: tickCursor)
                    out.append(.textMark(
                        kind: .tempo,
                        text: "♩ = \(bpm)",
                        origin: CGPoint(
                            x: tempoX
                                + CGFloat(t.offsetX) * metrics.sp,
                            y: staffMidY - metrics.sp * 4
                                + CGFloat(t.offsetY) * metrics.sp
                        )
                    ))
                case let .fermata(f):
                    // Fermata attaches to the preceding chord/rest; emit at
                    // the last placed timed x (or header cursor if still in
                    // header, though that's unusual).
                    let lastChordX = lastChordOrRestX(in: out)
                        ?? (inHeader
                            ? headerSchedule.contentStartX
                            : timedX(atTick: tickCursor))
                    out.append(.fermata(
                        subtype: f.subtype,
                        origin: CGPoint(
                            x: lastChordX,
                            y: staffMidY - metrics.sp * 3
                        )
                    ))
                case .measureRepeat:
                    out.append(.measureRepeat(
                        count: 1,
                        origin: CGPoint(x: width / 2, y: staffMidY)
                    ))
                case .spanner:
                    // Resolved at system level in the spanner-attach pass.
                    break
                case let .rehearsalMark(rm):
                    // System-flagged: drawn once above the top staff at
                    // measure-left. Only emit on staff 0 / voice 0 to
                    // avoid duplicates from linked-main mirrors and from
                    // other staves in a multi-staff piece. Y mirrors
                    // marker placement (`staffTopY - sp * 1.5` post-
                    // translation), which in staff-local coords is
                    // `staffMidY - sp * 3.5` (staffTopLocal = sp*2;
                    // staffMidY = staffTopLocal + staffHeight/2 = sp*4
                    // for 5-line staves; sp*4 - sp*3.5 ≈ sp*0.5 above
                    // the top line — matches MuseScore's default).
                    if staffAddress == StaffAddress(partIndex: 0, staffIndexInPart: 0) && voiceIdx == 0 {
                        let originX = inHeader
                            ? headerSchedule.contentStartX
                            : metrics.sp * 0.5
                        out.append(.rehearsalMark(
                            text: rm.text,
                            origin: CGPoint(
                                x: originX
                                    + CGFloat(rm.offsetX) * metrics.sp,
                                y: staffMidY - metrics.sp * 3.5
                                    + CGFloat(rm.offsetY) * metrics.sp
                            ),
                            frame: rm.frame,
                            color: rm.color
                        ))
                    }
                case let .locationShift(delta):
                    // Voice-level cursor shift. Adds the location's
                    // fractional delta to `tickCursor` so the next
                    // non-temporal element (text mark, dynamic,
                    // tempo, rehearsal mark) attaches at the
                    // shifted tick. Mirrors MuseScore's
                    // `setLocation` behaviour during voice read.
                    tickCursor += delta.ticks(division: division)
                case let .harmony(harmony):
                    // Hidden chord symbols contribute neither glyphs
                    // nor width — drop before measurement so the
                    // pre-spacing pass and autoplace stacking ignore
                    // them. Playback (`harmony.play`) is independent
                    // of visibility.
                    if !harmony.visible { break }
                    // Anchor at the next timed-element column (or
                    // header start while still in the header). Same
                    // anchoring rule as .staffText so multiple
                    // harmonies at the same tick share an X column
                    // (which the autoplace stacking pass relies on).
                    let stX = inHeader
                        ? headerSchedule.contentStartX
                        : timedX(atTick: tickCursor)
                    let runs = HarmonyRendering.runs(
                        for: harmony, metrics: metrics
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
                        stX + CGFloat(harmony.offsetX) * metrics.sp
                    )
                    out.append(.harmony(LayoutHarmony(
                        harmony: harmony,
                        anchorX: anchorX,
                        y: Double(yLocal),
                        runs: runs,
                        width: width
                    )))
                }
            }

            // Glissando emission pass: pair each glissando-bearing note
            // with the corresponding note (same index) in the next chord
            // of the same voice. Uses actual note origins (not stemOrigin)
            // so the line slopes between the two different pitches.
            let chordVoiceIndices = voiceChordOutIndex.keys.sorted()
            for (pairIdx, voiceIdx) in chordVoiceIndices.enumerated() {
                guard voiceIdx < voice.elements.count,
                      case let .chord(chord) = voice.elements[voiceIdx]
                else { continue }
                guard let glissNoteIdx = chord.notes
                    .firstIndex(where: { $0.glissando != nil }),
                    let gliss = chord.notes[glissNoteIdx].glissando
                else { continue }
                let nextPairIdx = pairIdx + 1
                guard nextPairIdx < chordVoiceIndices.count else { continue }
                let nextVoiceIdx = chordVoiceIndices[nextPairIdx]
                guard let fromOutIdx = voiceChordOutIndex[voiceIdx],
                      let toOutIdx = voiceChordOutIndex[nextVoiceIdx]
                else { continue }
                guard case let .chord(fromNotes, _, _, _, _, _, _, _) =
                    out[fromOutIdx],
                    case let .chord(toNotes, _, _, _, _, _, _, _) =
                    out[toOutIdx]
                else { continue }
                guard let fromFallback = fromNotes.last,
                      let toFallback = toNotes.last
                else { continue }
                let fromNote = glissNoteIdx < fromNotes.count
                    ? fromNotes[glissNoteIdx]
                    : fromFallback
                let toNote = glissNoteIdx < toNotes.count
                    ? toNotes[glissNoteIdx]
                    : toFallback
                // Offset x inward so the line starts past the from-
                // notehead and ends before the to-notehead.
                out.append(.glissandoLine(
                    fromOrigin: CGPoint(
                        x: fromNote.origin.x + metrics.sp * 0.8,
                        y: fromNote.origin.y
                    ),
                    toOrigin: CGPoint(
                        x: toNote.origin.x - metrics.sp * 0.8,
                        y: toNote.origin.y
                    ),
                    wavy: gliss.visualType == .wavy,
                    text: gliss.text
                ))
            }

            // Beaming pass for this voice.
            let groups = beamGroups(
                voice: voice,
                timeSignature: measureTimeSig,
                division: division
            )
            for group in groups {
                // --- Phase 1: collect all note steps for direction ---
                var groupSteps: [Int] = []
                for memberIdx in group.memberIndices {
                    guard let outIdx = voiceChordOutIndex[memberIdx],
                          case let .chord(n, _, _, _, _, _, _, _)
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
                var memberStemXs: [CGFloat] = []
                var anchorSteps: [Int] = []
                var anchorYs: [CGFloat] = []
                var memberLevels: [Int] = []
                for memberIdx in group.memberIndices {
                    guard let outIdx = voiceChordOutIndex[memberIdx],
                          case let .chord(n, _, _, so, _, _, _, _)
                          = out[outIdx]
                    else {
                        memberLevels.append(0)
                        continue
                    }
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
                guard memberStemXs.count >= 2,
                      let beamStartX = memberStemXs.first,
                      let beamEndX = memberStemXs.last
                else { continue }

                // --- Phase 3: sloped beam line ---
                let line = computeBeamLine(
                    anchorSteps: anchorSteps,
                    anchorYs: anchorYs,
                    stemXs: memberStemXs,
                    direction: groupDirection,
                    metrics: metrics
                )
                let beamSpan = beamEndX - beamStartX
                func beamYAt(_ x: CGFloat) -> CGFloat {
                    guard beamSpan > 0 else { return line.startY }
                    let t = (x - beamStartX) / beamSpan
                    return line.startY + (line.endY - line.startY) * t
                }
                let memberStemYs = memberStemXs.map(beamYAt)

                // --- Phase 4: rewrite each chord with its own beam y ---
                for (i, memberIdx) in group.memberIndices.enumerated() {
                    guard let outIdx = voiceChordOutIndex[memberIdx],
                          case let .chord(
                              n,
                              d,
                              _,
                              so,
                              arp,
                              art,
                              _,
                              vi
                          ) = out[outIdx]
                    else { continue }
                    out[outIdx] = .chord(
                        notes: n,
                        duration: d,
                        stem: groupDirection,
                        stemOrigin: CGPoint(
                            x: so.x, y: memberStemYs[i]
                        ),
                        hasArpeggio: arp,
                        arpeggioRawType: art,
                        isBeamed: true,
                        voiceIndex: vi
                    )
                }

                // --- Phase 5: emit per-level beam runs ---
                let maxLvl = memberLevels.max() ?? 0
                guard maxLvl >= 1 else { continue }
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
                                metrics: metrics,
                                out: &out
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
                            metrics: metrics,
                            out: &out
                        )
                    }
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
                        division: division
                    ),
                    staffMidY: staffMidY,
                    metrics: metrics,
                    tupletID: TupletID(
                        staff: staffAddress,
                        measureIndex: measureIndex,
                        voiceIndex: voiceIdx,
                        startElementIndex: tuplet.startIndex
                    )
                )
            }
        }

        // Trailing bar line if no voice emitted one.
        // The final measure of the score gets a "end" barline
        // (thin + thick) per standard engraving convention.
        let hasExplicitBar = out.contains {
            if case .barLine = $0 { true } else { false }
        }
        if !hasExplicitBar {
            out.append(.barLine(
                subtype: isLastMeasure ? "end" : nil,
                origin: CGPoint(
                    x: width - metrics.sp / 2,
                    y: staffMidY
                )
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
                out: &out
            )
        }
        // Auto-place staff text: shift it above any chord stem /
        // beam in this measure. MuseScore does this in its skyline-
        // based autoplace step (`Autoplace::autoplaceStaffText`);
        // we approximate by bumping every staff text in the measure
        // by the same amount so the layout stays simple while the
        // visual outcome — text never overlaps a stem or beam —
        // matches.
        autoPlaceStaffText(
            in: &out, staffMidY: staffMidY, metrics: metrics
        )
        // Same chord-clearance pass for chord symbols. Without this,
        // a chord whose noteheads or beam reach above the harmony's
        // default Y (`staffTop - 2.5 sp`) collides with the symbol —
        // common when the staff carries notes more than one ledger
        // line above the top staff line.
        autoPlaceHarmony(
            in: &out, staffMidY: staffMidY, metrics: metrics
        )
        // After per-element auto-place, resolve same-tick collisions
        // among above-staff text marks (tempo / staff text / system
        // text / rehearsal mark) by stacking them upward.
        autoStackAboveStaffMarks(in: &out, metrics: metrics)
        return (out, currentClef, currentKey)
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
        stem: StemDirection
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
        // stem-up, right for stem-down. (MuseScore initialises
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
                mirror: mirrors[i]
            )
        }
    }

    // swiftlint:disable function_parameter_count
    /// Build `LayoutChordNote` values for a single `GraceChord`.
    /// Mirrors the inline notehead construction used for main chords
    /// but takes `graceIdx` / `isAfter` so synthesized `NoteID`s
    /// don't collide with the parent chord's notes — important for
    /// hit-testing and the chord-origin lookup.
    fileprivate static func makeGraceLayoutNotes(
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
        drumLineMap: [Int: Int]?
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
                    clef: currentClef
                ).step
            }
            let y = staffMidY - CGFloat(step) * metrics.sp / 2
            let id = NoteID(
                staff: staffAddress,
                measureIndex: measureIndex,
                voiceIndex: voiceIdx,
                elementIndex: voiceElemIdx,
                noteIndexInChord: base + noteIdx
            )
            return LayoutChordNote(
                noteID: id,
                step: step,
                accidental: note.accidental,
                origin: CGPoint(x: x, y: y),
                tieForward: nil, tieBack: nil,
                hasGlissando: false,
                headType: note.headType
            )
        }
    }
    // swiftlint:enable function_parameter_count
}
