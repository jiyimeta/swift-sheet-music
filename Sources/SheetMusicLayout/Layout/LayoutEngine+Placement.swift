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
                    voiceRestOutIndex[voiceElemIdx] = out.count
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
                    let preliminaryNotes = chord.notes.enumerated().map {
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
                            for: preliminaryNotes.map(\.step))
                    let chordNotes = applyChordMirroring(
                        preliminaryNotes, stem: stem)
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
                    voiceRestOutIndex: voiceRestOutIndex,
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
        let order: [Int] = (0..<notes.count).sorted { i, j in
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
                isLeft = !isLeft
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
                mirror: mirrors[i])
        }
    }
}
