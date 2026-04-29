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
        staffIndex: Int,
        measureIndex: Int,
        width: CGFloat,
        metrics: StaffMetrics,
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
                if case .timeSignature(let ts) = el {
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
           !firstVoiceStartsWithClef(measure: measure) {
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
           !firstVoiceHasLeadingKeySig(measure: measure) {
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
            v.elements.contains { if case .chord = $0 { true } else { false } }
        }.count
        let voicesWithContent = measure.voices.filter { v in
            v.elements.contains { el in
                switch el {
                case .chord, .rest: return true
                default: return false
                }
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
                case .chord(let c):
                    return acc + c.duration.ticks(division: division)
                case .rest(let r):
                    return acc + r.duration.ticks(division: division)
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
                   :  metrics.sp * 2)
                : 0

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
                    guard case .chord(let chord) = el else { continue }
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
                                noteheadBottom + metrics.sp * 0.8)
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
                        x: headerSchedule.clefX, y: staffMidY)))
                remainingSynthClef = false
            }
            // Emit the synthesized leading key signature once, after
            // the clef column.
            if remainingSynthKeySig, let k = initialKeyForSynth {
                out.append(.keySignature(
                    sharps: max(0, k),
                    flats: max(0, -k),
                    origin: CGPoint(
                        x: headerSchedule.keySigX, y: staffMidY)))
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
                case .clef(let clef):
                    currentClef = NotatedClef(rawType: clef.concertClefType)
                    let clefX = inHeader ? headerSchedule.clefX
                        : timedX(atTick: tickCursor)
                    out.append(.clef(
                        rawType: clef.concertClefType,
                        origin: CGPoint(x: clefX, y: staffMidY)))
                case .keySignature(let key):
                    currentKey = key.concertKey
                    let keyX = inHeader ? headerSchedule.keySigX : timedX(atTick: tickCursor)
                    out.append(.keySignature(
                        sharps: max(0, key.concertKey),
                        flats: max(0, -key.concertKey),
                        origin: CGPoint(x: keyX, y: staffMidY)))
                case .timeSignature(let ts):
                    let tsX = inHeader ? headerSchedule.timeSigX : timedX(atTick: tickCursor)
                    out.append(.timeSignature(
                        numerator: ts.numerator,
                        denominator: ts.denominator,
                        origin: CGPoint(x: tsX, y: staffMidY)))
                case .barLine(let b):
                    let barX = inHeader ? metrics.sp : timedX(atTick: tickCursor)
                    out.append(.barLine(
                        subtype: b.subtype,
                        origin: CGPoint(x: barX, y: staffMidY)))
                case .rest(let r):
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
                        staffIndex: staffIndex,
                        measureIndex: measureIndex,
                        voiceIndex: voiceIdx,
                        elementIndex: voiceElemIdx)
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
                    out.append(.rest(
                        duration: r.duration,
                        origin: CGPoint(x: restX, y: restY),
                        voiceIndex: voiceIdx,
                        restID: restID,
                        hasLegerLine: needsLeger))
                    tickCursor += r.duration.ticks(division: division)
                case .chord(let chord):
                    inHeader = false
                    // Every element at a shared tick lives at the same
                    // x. Flag glyphs extend ~1 sp to the right of the
                    // stem, but that's a visual-only concern — shifting
                    // the notehead itself would desynchronise flagged
                    // chords from rests (and from notes in other
                    // voices) that share the same tick.
                    let chordX = timedX(atTick: tickCursor)
                    let chordNotes = chord.notes.enumerated().map {
                        (noteIdx, note) -> LayoutChordNote in
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
                            staffIndex: staffIndex,
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
                            for: chordNotes.map(\.step))
                    voiceChordOutIndex[voiceElemIdx] = out.count
                    out.append(.chord(
                        notes: chordNotes,
                        duration: chord.duration,
                        stem: stem,
                        stemOrigin: CGPoint(x: chordX, y: staffMidY),
                        hasArpeggio: chord.arpeggio != nil,
                        arpeggioRawType: chord.arpeggio.flatMap(arpeggioSubtype),
                        isBeamed: false,
                        voiceIndex: voiceIdx))
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
                            origin: CGPoint(x: chordX, y: lyricsY)))
                        let textWidth = Self.lyricsTextWidth(
                            lyric.text, sp: metrics.sp)
                        // Hyphens between this syllable and the
                        // previous one in the same verse.
                        if let prev = previousLyric[verseIdx],
                           connectsWithHyphen(
                            prev: prev.syllabic,
                            curr: lyric.syllabic) {
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
                                out: &out)
                        }
                        previousLyric[verseIdx] = LyricTrail(
                            centerX: chordX,
                            textWidth: textWidth,
                            lyricsY: lyricsY,
                            syllabic: lyric.syllabic)
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
                                out: &out)
                        }
                    }
                    tickCursor += chordTicks
                case .dynamic(let d):
                    // Dynamics sit below-left of the note they apply to
                    // (i.e. the next timed element at the current tick).
                    // Shift 1 sp left so the label doesn't overlap the
                    // following chord's notehead or stem.
                    let baseX = inHeader
                        ? headerSchedule.contentStartX
                        : timedX(atTick: tickCursor)
                    out.append(.textMark(
                        kind: .dynamic,
                        text: d.subtype,
                        origin: CGPoint(
                            x: baseX - metrics.sp,
                            y: staffMidY + metrics.sp * 4)))
                case .staffText(let st):
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
                                + CGFloat(st.offsetY) * metrics.sp),
                        color: st.color,
                        isSystemText: st.isSystemText))
                case .tempo(let t):
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
                            x: tempoX,
                            y: staffMidY - metrics.sp * 4)))
                case .fermata(let f):
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
                            y: staffMidY - metrics.sp * 3)))
                case .measureRepeat:
                    out.append(.measureRepeat(
                        count: 1,
                        origin: CGPoint(x: width / 2, y: staffMidY)))
                case .spanner:
                    // Resolved at system level in the spanner-attach pass.
                    break
                case .rehearsalMark(let rm):
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
                    if staffIndex == 0 && voiceIdx == 0 {
                        let originX = inHeader
                            ? headerSchedule.contentStartX
                            : metrics.sp * 0.5
                        out.append(.rehearsalMark(
                            text: rm.text,
                            origin: CGPoint(
                                x: originX
                                    + CGFloat(rm.offsetX) * metrics.sp,
                                y: staffMidY - metrics.sp * 3.5
                                    + CGFloat(rm.offsetY) * metrics.sp),
                            frame: rm.frame,
                            color: rm.color))
                    }
                }
            }

            // Glissando emission pass: pair each glissando-bearing note
            // with the corresponding note (same index) in the next chord
            // of the same voice. Uses actual note origins (not stemOrigin)
            // so the line slopes between the two different pitches.
            let chordVoiceIndices = voiceChordOutIndex.keys.sorted()
            for (pairIdx, voiceIdx) in chordVoiceIndices.enumerated() {
                guard voiceIdx < voice.elements.count,
                      case .chord(let chord) = voice.elements[voiceIdx]
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
                guard case .chord(let fromNotes, _, _, _, _, _, _, _) =
                        out[fromOutIdx],
                      case .chord(let toNotes, _, _, _, _, _, _, _) =
                        out[toOutIdx]
                else { continue }
                let fromNote = glissNoteIdx < fromNotes.count
                    ? fromNotes[glissNoteIdx]
                    : fromNotes.last!
                let toNote = glissNoteIdx < toNotes.count
                    ? toNotes[glissNoteIdx]
                    : toNotes.last!
                // Offset x inward so the line starts past the from-
                // notehead and ends before the to-notehead.
                out.append(.glissandoLine(
                    fromOrigin: CGPoint(
                        x: fromNote.origin.x + metrics.sp * 0.8,
                        y: fromNote.origin.y),
                    toOrigin: CGPoint(
                        x: toNote.origin.x - metrics.sp * 0.8,
                        y: toNote.origin.y),
                    wavy: gliss.visualType == .wavy,
                    text: gliss.text
                ))
            }

            // Beaming pass for this voice.
            let groups = beamGroups(
                voice: voice,
                timeSignature: measureTimeSig,
                division: division)
            for group in groups {
                // --- Phase 1: collect all note steps for direction ---
                var groupSteps: [Int] = []
                for memberIdx in group.memberIndices {
                    guard let outIdx = voiceChordOutIndex[memberIdx],
                          case .chord(let n, _, _, _, _, _, _, _)
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
                          case .chord(let n, _, _, let so, _, _, _, _)
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
                    if case .chord(let c) = voice.elements[memberIdx] {
                        memberLevels.append(beamLevel(c.duration))
                    } else {
                        memberLevels.append(0)
                    }
                }
                guard memberStemXs.count >= 2 else { continue }

                // --- Phase 3: sloped beam line ---
                let line = computeBeamLine(
                    anchorSteps: anchorSteps,
                    anchorYs: anchorYs,
                    stemXs: memberStemXs,
                    direction: groupDirection,
                    metrics: metrics)
                let beamStartX = memberStemXs.first!
                let beamEndX = memberStemXs.last!
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
                          case .chord(let n, let d, _, let so,
                                      let arp, let art, _, let vi) = out[outIdx]
                    else { continue }
                    out[outIdx] = .chord(
                        notes: n,
                        duration: d,
                        stem: groupDirection,
                        stemOrigin: CGPoint(
                            x: so.x, y: memberStemYs[i]),
                        hasArpeggio: arp,
                        arpeggioRawType: art,
                        isBeamed: true,
                        voiceIndex: vi)
                }

                // --- Phase 5: emit per-level beam runs ---
                let maxLvl = memberLevels.max() ?? 0
                guard maxLvl >= 1 else { continue }
                for lvl in 1...maxLvl {
                    var runStart: Int?
                    for i in 0..<memberLevels.count {
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
                                out: &out)
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
                            out: &out)
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
                    out: &out,
                    beamGroups: beamGroups(
                        voice: voice,
                        timeSignature: measureTimeSig,
                        division: division),
                    staffMidY: staffMidY,
                    metrics: metrics)
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
                    y: staffMidY)))
        }
        for continuation in incomingMelismas {
            emitMelismaContinuation(
                continuation: continuation,
                staffMidY: staffMidY,
                tickColumns: tickColumns,
                headerContentStartX: headerSchedule.contentStartX,
                measureWidth: width,
                metrics: metrics,
                out: &out)
        }
        // Auto-place staff text: shift it above any chord stem /
        // beam in this measure. MuseScore does this in its skyline-
        // based autoplace step (`Autoplace::autoplaceStaffText`);
        // we approximate by bumping every staff text in the measure
        // by the same amount so the layout stays simple while the
        // visual outcome — text never overlaps a stem or beam —
        // matches.
        autoPlaceStaffText(
            in: &out, staffMidY: staffMidY, metrics: metrics)
        return (out, currentClef, currentKey)
    }

    /// True when consecutive same-verse syllables should be linked
    /// with a hyphen line. MuseScore draws dashes between any
    /// `begin`/`middle` and the next `middle`/`end` syllable; the
    /// boundary cases (`single→…`, `…→single`, `…→begin`) start a
    /// new word so no hyphen is drawn.
    private static func connectsWithHyphen(
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
    private static func emitLyricHyphens(
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
        for i in 0..<dashCount {
            xCenter += i == 0 ? 0.5 * dashDist : dashDist
            let centerX = fromX + xCenter
            out.append(.lyricHyphen(
                fromOrigin: CGPoint(
                    x: centerX - 0.5 * dashWidth, y: y),
                toOrigin: CGPoint(
                    x: centerX + 0.5 * dashWidth, y: y)))
        }
    }

    /// Maximum upward extent (smallest Y) of any chord stem-tip,
    /// notehead, or beam in `elements`. Used by the staff-text
    /// auto-placement post-pass. Returns `+infinity` when the
    /// measure has no chords/beams.
    private static func chordTopExtent(
        in elements: [LayoutElement]
    ) -> CGFloat {
        var minY = CGFloat.infinity
        for el in elements {
            switch el {
            case .chord(let notes, _, let dir, let stemOrigin,
                        _, _, _, _):
                let topNote = notes.map(\.origin.y).min()
                    ?? stemOrigin.y
                let extent = dir == .up
                    ? min(stemOrigin.y, topNote)
                    : topNote
                minY = min(minY, extent)
            case .beam(let from, let to, _, _):
                minY = min(minY, from.y, to.y)
            default:
                break
            }
        }
        return minY
    }

    /// Shift every `.staffText` in `out` upward as needed so that
    /// its Y clears the topmost chord/beam in the measure. The
    /// user-supplied vertical offset (already baked into the
    /// element's `origin.y` during placement) is preserved — only
    /// the BASE position changes; the offset shifts relative to it.
    private static func autoPlaceStaffText(
        in out: inout [LayoutElement],
        staffMidY: CGFloat,
        metrics: StaffMetrics
    ) {
        let chordTop = chordTopExtent(in: out)
        guard chordTop.isFinite else { return }
        // Default placement Y matches the constant used when the
        // text was first emitted (`staffMidY - sp * 3`). The auto
        // base sits 1.5 sp above the highest chord/beam point.
        let defaultBase = staffMidY - metrics.sp * 3
        let autoBase = chordTop - metrics.sp * 1.5
        // Only shift when the chord is actually pushing into the
        // text's default zone — otherwise leave the layout alone.
        guard autoBase < defaultBase else { return }
        let shift = autoBase - defaultBase
        for i in 0..<out.count {
            if case .staffText(let text, let p, let color,
                               let isSystem) = out[i] {
                out[i] = .staffText(
                    text: text,
                    origin: CGPoint(x: p.x, y: p.y + shift),
                    color: color,
                    isSystemText: isSystem)
            }
        }
    }

    /// Emit the left-hand continuation rule that shows a melisma
    /// started in an earlier measure is still active here.
    private static func emitMelismaContinuation(
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
            measureWidth - metrics.sp)
        let crossingRightX = measureWidth
        let sortedTicks = tickColumns.keys.sorted()
        let endX: CGFloat
        if continuation.continuesPastMeasure {
            endX = crossingRightX
        } else if let t = sortedTicks.first(
            where: { $0 >= continuation.endTick }),
           let nextX = tickColumns[t] {
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
            toOrigin: CGPoint(x: endX, y: lyricsY)))
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
        for (staffIdx, staff) in score.staves.enumerated() {
            for (mIdx, measure) in staff.measures.enumerated() {
                for (vIdx, voice) in measure.voices.enumerated() {
                    for (eIdx, el) in voice.elements.enumerated() {
                        guard case .chord(let chord) = el else { continue }
                        for (verseIdx, lyric)
                        in chord.lyrics.enumerated()
                        where !lyric.text.isEmpty {
                            map[MelismaLyricKey(
                                staffIndex: staffIdx,
                                measureIndex: mIdx,
                                voiceIndex: vIdx,
                                elementIndex: eIdx,
                                verseIndex: verseIdx)] = lyric.ticks
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
        var result: [[[MelismaContinuation]]] = score.staves.map {
            Array(repeating: [], count: $0.measures.count)
        }
        for (staffIdx, staff) in score.staves.enumerated() {
            let voiceCount = staff.measures
                .map(\.voices.count).max() ?? 0
            for voiceIdx in 0..<voiceCount {
                // Pre-compute total voice ticks per measure so the
                // inner loop doesn't rescan them repeatedly.
                let tickCounts: [Int] = staff.measures.map { m in
                    guard voiceIdx < m.voices.count else { return 0 }
                    var total = 0
                    for el in m.voices[voiceIdx].elements {
                        switch el {
                        case .chord(let c):
                            total += c.duration.ticks(division: division)
                        case .rest(let r):
                            total += r.duration.ticks(division: division)
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
                    in measure.voices[voiceIdx].elements.enumerated() {
                        switch el {
                        case .chord(let c):
                            let chordTicks = c.duration
                                .ticks(division: division)
                            for (verseIdx, lyric)
                            in c.lyrics.enumerated()
                            where !lyric.text.isEmpty {
                                let key = MelismaLyricKey(
                                    staffIndex: staffIdx,
                                    measureIndex: mIdx,
                                    voiceIndex: voiceIdx,
                                    elementIndex: eIdx,
                                    verseIndex: verseIdx)
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
                                    result: &result[staffIdx])
                            }
                            tickInMeasure += chordTicks
                        case .rest(let r):
                            tickInMeasure += r.duration
                                .ticks(division: division)
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
                        continuesPastMeasure: true))
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
                        continuesPastMeasure: false))
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
                    continuesPastMeasure: true))
            }
            currentMeasure += 1
            currentTick = 0
        }
    }

    /// Horizontal distance from a note's anchor x to its
    /// notehead right edge. Bravura's `noteheadBlack` is 1.18 sp
    /// wide (half-width 0.59 sp); whole / half noteheads are a
    /// touch wider. We pick 0.7 sp as a single constant that
    /// covers every notehead family with a small safety margin
    /// without bleeding into the next note's space.
    private static func noteheadHalfExtent(sp: CGFloat) -> CGFloat {
        sp * 0.7
    }

    /// Lowest Y a chord's geometry occupies BELOW the staff,
    /// in measure-local coords. Used to push lyrics below low
    /// noteheads / ties-below so they don't overlap.
    /// Approximates the "south skyline" MuseScore computes for
    /// collision avoidance in `lyricslayout.cpp`.
    ///
    /// Counts only elements that actually hang below the staff —
    /// noteheads with `step ≤ -4` and tie arcs on the lowest
    /// note. Stem direction is NOT included: stem-down chords
    /// have their stem extending opposite to the lyric direction
    /// in the upper half of the staff (where stem-down is the
    /// engraving rule), and stem-up stems point away from the
    /// lyric area entirely. Including stem length here pushed
    /// every stem-down chord's lyric down by ~0.6 sp,
    /// disconnecting melisma rules from their continuation rules
    /// in subsequent measures.
    static func chordSouthExtent(
        notes: [LayoutChordNote],
        stem: StemDirection,
        staffMidY: CGFloat,
        metrics: StaffMetrics
    ) -> CGFloat {
        guard let lowestStep = notes.map(\.step).min() else {
            return staffMidY
        }
        let lowestNoteY = staffMidY
            - CGFloat(lowestStep) * metrics.sp / 2
        let noteheadBottom = lowestNoteY + metrics.sp * 0.5
        var south = noteheadBottom
        // Ties on the lowest note arc downward when the stem
        // is up (they go opposite to the stem). The arc peaks
        // ~0.8 sp below the notehead bottom.
        if stem == .up {
            let hasTie = notes.contains { (n: LayoutChordNote) in
                n.tieForward != nil || n.tieBack != nil
            }
            if hasTie {
                south = max(
                    south, noteheadBottom + metrics.sp * 0.8)
            }
        }
        return south
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
            kCTFontWeightTrait: 0.3
        ] as CFDictionary
        let attributes: CFDictionary = [
            kCTFontTraitsAttribute: traits,
            kCTFontSizeAttribute: fontSize,
        ] as CFDictionary
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes)
        let font = CTFontCreateWithFontDescriptor(descriptor, fontSize, nil)
        let attrs: CFDictionary = [
            kCTFontAttributeName: font
        ] as CFDictionary
        guard let attrString = CFAttributedStringCreate(
            nil, text as CFString, attrs)
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
    private static func melismaLineYOffset(sp: CGFloat) -> CGFloat {
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
    private static func emitMelismaLine(
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
            measureWidth - metrics.sp)
        let crossingRightX = measureWidth
        let sortedTicks = tickColumns.keys.sorted()
        let endX: CGFloat
        if let t = sortedTicks.first(where: { $0 >= endTick }),
           let nextX = tickColumns[t] {
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
            lyricText, sp: metrics.sp)
        let lineStartX = chordX + textWidth / 2 + metrics.sp * 0.25
        // Only emit if there is actually a visible line to draw —
        // avoids a one-pixel stub when the estimate pushes
        // `lineStartX` past `endX`.
        guard endX > lineStartX + metrics.sp * 0.5 else { return }
        out.append(.lyricsMelisma(
            fromOrigin: CGPoint(x: lineStartX, y: lyricsY),
            toOrigin: CGPoint(x: endX, y: lyricsY)))
    }

    /// Extract a render-ready subtype string from the Core `Arpeggio` value.
    /// `Arpeggio.subtype` is MuseScore's mscx integer code
    /// (0=NORMAL, 1=UP, 2=DOWN, 3=UP_STRAIGHT, 4=DOWN_STRAIGHT, 5=BRACKET).
    /// `ArpeggioRenderer` consumes "up" / "down" / nil — map accordingly.
    static func arpeggioSubtype(_ arp: Arpeggio) -> String? {
        switch arp.subtype {
        case 1, 3: return "up"
        case 2, 4: return "down"
        default: return nil
        }
    }

    // MARK: - Placement helpers

    /// Width consumed by the leading header (clef / key sig / time sig)
    /// of the first voice that has such elements. Measured from the left
    /// padding, inclusive of `startPadding`.
    private static func headerWidth(
        measure: Measure,
        metrics: StaffMetrics,
        startPadding: CGFloat
    ) -> CGFloat {
        var w = startPadding
        let voice = measure.voices.first
        guard let elements = voice?.elements else { return w }
        for el in elements {
            switch el {
            case .clef: w += metrics.sp * 3
            case .keySignature(let k):
                w += metrics.sp * (CGFloat(abs(k.concertKey)) + 1.5)
            case .timeSignature: w += metrics.sp * 3
            case .chord, .rest:
                return w   // first timed element ends the header
            default:
                continue
            }
        }
        return w
    }

    /// Emit a `.tupletLabel` for one `Tuplet` span. Picks bracket vs
    /// number-only based on whether every member sits inside the same
    /// beam group (MuseScore's simplified auto-bracket rule).
    private static func emitTupletLabel(
        tuplet: Tuplet,
        voice: Voice,
        voiceChordOutIndex: [Int: Int],
        out: inout [LayoutElement],
        beamGroups: [BeamGroup],
        staffMidY: CGFloat,
        metrics: StaffMetrics
    ) {
        // Collect the out-array indices of members that are chords
        // (rests have no stemOrigin to reference — we fall back to a
        // per-member rest-scan if we need them).
        var chordStemXs: [CGFloat] = []
        var chordAnchorYs: [CGFloat] = []   // beam-side note y (outer note)
        var chordStemsUp = 0
        var chordCount = 0
        var containsRest = false
        for idx in tuplet.startIndex...tuplet.endIndex {
            let el = voice.elements[idx]
            switch el {
            case .chord:
                chordCount += 1
            case .rest:
                containsRest = true
            default:
                continue
            }
            guard let outIdx = voiceChordOutIndex[idx],
                  case .chord(let notes, _, let stem, let so,
                              _, _, _, _) = out[outIdx]
            else { continue }
            chordStemXs.append(so.x)
            if stem == .up { chordStemsUp += 1 }
            let anchorY: CGFloat
            if stem == .up {
                anchorY = notes.map(\.origin.y).min() ?? so.y
            } else {
                anchorY = notes.map(\.origin.y).max() ?? so.y
            }
            chordAnchorYs.append(anchorY)
        }
        guard !chordStemXs.isEmpty else { return }

        // MuseScore's bracket rule (Tuplet::calcHasBracket): hide the
        // bracket when the first AND last tuplet members sit inside
        // the SAME beam AND no member is a rest. The beam can be
        // larger than the tuplet — what matters is that both ends
        // share one continuous beam.
        let isBeamedGroup = !containsRest
            && beamGroups.contains { bg in
                bg.memberIndices.contains(tuplet.startIndex)
                && bg.memberIndices.contains(tuplet.endIndex)
            }

        // Place the marking above stem-up groups, below stem-down.
        let isAbove = chordStemsUp * 2 >= chordCount

        // Horizontal span — first to last chord's stem x.
        let fromX = chordStemXs.first!
        let toX = chordStemXs.last!

        // Vertical position:
        // - Beamed: just above/below the beam (= stemOrigin.y for the
        //   first and last members, already sloped).
        // - Bracketed: clear of the outer anchor by stemLen + 2 sp.
        let labelPad = metrics.sp * 1.5
        let fromY: CGFloat
        let toY: CGFloat
        if isBeamedGroup {
            // Use the chord's stemOrigin.y (which IS the beam y for
            // beamed chords) as the reference line; offset outward so
            // the number sits clear of the beam.
            guard
                let firstIdx = voiceChordOutIndex[tuplet.startIndex],
                let lastIdx = voiceChordOutIndex[tuplet.endIndex],
                case .chord(_, _, _, let firstSO, _, _, _, _) = out[firstIdx],
                case .chord(_, _, _, let lastSO, _, _, _, _) = out[lastIdx]
            else { return }
            let outward: CGFloat = isAbove ? -labelPad : labelPad
            fromY = firstSO.y + outward
            toY = lastSO.y + outward
        } else {
            // Bracket sits past the outer anchor by a fixed amount.
            let extremeY: CGFloat
            if isAbove {
                extremeY = chordAnchorYs.min() ?? staffMidY
            } else {
                extremeY = chordAnchorYs.max() ?? staffMidY
            }
            let outward: CGFloat = isAbove
                ? -(metrics.defaultStemLength + labelPad)
                : (metrics.defaultStemLength + labelPad)
            fromY = extremeY + outward
            toY = fromY  // flat bracket — MuseScore sometimes slopes,
            //            but a flat bracket is the common case.
        }

        // Clamp so the bracket/number never falls inside the staff
        // lines (placement-local: staff top = sp*2, bottom = sp*6).
        let staffTop = metrics.sp * 2 - metrics.sp  // 1 sp above top line
        let staffBot = metrics.sp * 6 + metrics.sp  // 1 sp below bot line
        let clampedFromY: CGFloat
        let clampedToY: CGFloat
        if isAbove {
            clampedFromY = min(fromY, staffTop)
            clampedToY = min(toY, staffTop)
        } else {
            clampedFromY = max(fromY, staffBot)
            clampedToY = max(toY, staffBot)
        }

        out.append(.tupletLabel(
            fromOrigin: CGPoint(x: fromX, y: clampedFromY),
            toOrigin: CGPoint(x: toX, y: clampedToY),
            text: "\(tuplet.actualNotes)",
            hasBracket: !isBeamedGroup,
            isAbove: isAbove))
    }

    /// Emit a single beam bar for a run of consecutive members that
    /// share the given level. Multi-member runs span from the first
    /// member's stem tip to the last's; single-member runs become a
    /// partial stub pointing back toward the neighbour (or forward if
    /// the lone member is first in the group). All endpoints are
    /// anchored to the sloped beam line via `beamYAt` so sloped beams
    /// keep secondary bars parallel to the primary.
    private static func emitBeamRun(
        start: Int,
        end: Int,
        level: Int,
        memberStemXs: [CGFloat],
        memberStemYs: [CGFloat],
        memberCount: Int,
        beamYAt: (CGFloat) -> CGFloat,
        direction: StemDirection,
        metrics: StaffMetrics,
        out: inout [LayoutElement]
    ) {
        if end > start {
            out.append(.beam(
                fromOrigin: CGPoint(
                    x: memberStemXs[start],
                    y: memberStemYs[start]),
                toOrigin: CGPoint(
                    x: memberStemXs[end],
                    y: memberStemYs[end]),
                direction: direction,
                level: level))
            return
        }
        let stubLen = metrics.sp * 1.5
        let x = memberStemXs[start]
        let fromX: CGFloat
        let toX: CGFloat
        if start > 0 {
            fromX = x - stubLen
            toX = x
        } else if end < memberCount - 1 {
            fromX = x
            toX = x + stubLen
        } else {
            return
        }
        out.append(.beam(
            fromOrigin: CGPoint(x: fromX, y: beamYAt(fromX)),
            toOrigin: CGPoint(x: toX, y: beamYAt(toX)),
            direction: direction,
            level: level))
    }

    /// True when the first voice's first element is a `<Clef>`. Used to
    /// decide whether to synthesize an implicit opening clef.
    private static func firstVoiceStartsWithClef(
        measure: Measure
    ) -> Bool {
        guard let firstElement = measure.voices.first?.elements.first
        else { return false }
        if case .clef = firstElement { return true }
        return false
    }

    /// True when the first voice's leading (pre-timed-content) run
    /// contains a `<KeySig>`.  Used to skip key-signature synthesis
    /// when the measure already has an explicit one.
    private static func firstVoiceHasLeadingKeySig(
        measure: Measure
    ) -> Bool {
        guard let elements = measure.voices.first?.elements else {
            return false
        }
        for el in elements {
            switch el {
            case .keySignature:
                return true
            case .chord, .rest:
                return false
            default:
                continue
            }
        }
        return false
    }

    /// Find the x coordinate of the most recently emitted chord or rest
    /// in `elements`, for positioning attached marks like fermatas.
    private static func lastChordOrRestX(
        in elements: [LayoutElement]
    ) -> CGFloat? {
        for el in elements.reversed() {
            switch el {
            case .chord(_, _, _, let origin, _, _, _, _):
                return origin.x
            case .rest(_, let origin, _, _, _):
                return origin.x
            default: continue
            }
        }
        return nil
    }
}
