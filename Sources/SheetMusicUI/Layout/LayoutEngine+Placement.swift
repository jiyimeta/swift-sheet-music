#if os(macOS)
import CoreGraphics
import SheetMusicCore

@available(macOS 15.0, *)
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
        width: CGFloat,
        metrics: StaffMetrics,
        activeClef: NotatedClef,
        initialClefRawType: String? = nil,
        headerSchedule: HeaderSchedule,
        division: Int,
        drumLineMap: [Int: Int]? = nil
    ) -> (elements: [LayoutElement], clef: NotatedClef) {
        let staffMidY = metrics.staffHeight / 2 + metrics.sp * 2
        var out: [LayoutElement] = []
        var currentClef = activeClef

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

        // Content width uses the shared schedule, so timed elements in
        // this staff align with timed elements in every other staff of
        // the same system.
        let trailingGap = metrics.sp * 3
        let contentWidth = max(
            metrics.sp * 4,
            width - headerSchedule.contentStartX - trailingGap)

        // --- Pass 2: emit elements for each voice ---
        //
        // Multi-voice detection (MuseScore's hasVoices): a measure
        // uses multiple voices when more than one voice contains at
        // least one chord. In that mode:
        //  - Voice 0 / 2: stems forced UP
        //  - Voice 1 / 3: stems forced DOWN
        //  - Rest y offset: voice 0 stays normal, voice 1 shifts down
        let voicesWithChords = measure.voices.filter { v in
            v.elements.contains { if case .chord = $0 { true } else { false } }
        }.count
        let isMultiVoice = voicesWithChords > 1

        var remainingSynthClef = synthesizeLeadingClef
        for (voiceIdx, voice) in measure.voices.enumerated() {
            let voiceTotal = totalTicks(in: voice, division: division)
            var tickCursor = 0
            var inHeader = true
            var voiceChordOutIndex: [Int: Int] = [:]

            // Forced stem direction for multi-voice measures.
            let forcedStem: StemDirection? = isMultiVoice
                ? (voiceIdx.isMultiple(of: 2) ? .up : .down)
                : nil
            // Rest y offset when multi-voice to avoid collision.
            let restVoiceOffset: CGFloat = isMultiVoice
                ? (voiceIdx.isMultiple(of: 2)
                   ? -metrics.sp * 2
                   :  metrics.sp * 2)
                : 0

            // Emit the synthesized leading clef exactly once, at the top
            // of the first voice to process it.
            if remainingSynthClef, let rawType = initialClefRawType {
                out.append(.clef(
                    rawType: rawType,
                    origin: CGPoint(
                        x: headerSchedule.clefX, y: staffMidY)))
                remainingSynthClef = false
            }

            /// x-coordinate for the next timed element based on tick.
            func timedX() -> CGFloat {
                guard voiceTotal > 0 else {
                    return headerSchedule.contentStartX + metrics.sp
                }
                let fraction = CGFloat(tickCursor) / CGFloat(voiceTotal)
                return headerSchedule.contentStartX
                    + metrics.sp + fraction * contentWidth
            }

            for (voiceIdx, el) in voice.elements.enumerated() {
                switch el {
                case .clef(let clef):
                    currentClef = NotatedClef(rawType: clef.concertClefType)
                    let clefX = inHeader ? headerSchedule.clefX : timedX()
                    out.append(.clef(
                        rawType: clef.concertClefType,
                        origin: CGPoint(x: clefX, y: staffMidY)))
                case .keySignature(let key):
                    let keyX = inHeader ? headerSchedule.keySigX : timedX()
                    out.append(.keySignature(
                        sharps: max(0, key.concertKey),
                        flats: max(0, -key.concertKey),
                        origin: CGPoint(x: keyX, y: staffMidY)))
                case .timeSignature(let ts):
                    let tsX = inHeader ? headerSchedule.timeSigX : timedX()
                    out.append(.timeSignature(
                        numerator: ts.numerator,
                        denominator: ts.denominator,
                        origin: CGPoint(x: tsX, y: staffMidY)))
                case .barLine(let b):
                    let barX = inHeader ? metrics.sp : timedX()
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
                    // A whole-measure rest is centered horizontally.
                    let isWholeRest = restBase == .whole
                    let restX: CGFloat
                    if isWholeRest {
                        restX = (headerSchedule.contentStartX + width
                                 - metrics.sp * 3) / 2
                    } else {
                        restX = timedX()
                    }
                    out.append(.rest(
                        duration: r.duration,
                        origin: CGPoint(x: restX, y: restY)))
                    tickCursor += r.duration.ticks(division: division)
                case .chord(let chord):
                    inHeader = false
                    // Shift flagged notes left so the visual centre of
                    // the notehead + flag combination sits on the tick
                    // position. The flag extends ~1 sp right of the
                    // stem; a 0.3 sp left-shift balances this. For
                    // beamed chords the flag isn't drawn, but the
                    // tiny shift is invisible and harmless.
                    let (chordBase, _) = DurationInterpretation.split(
                        chord.duration)
                    let flagShift: CGFloat
                    switch chordBase {
                    case .eighth, .sixteenth, .thirtySecond,
                         .sixtyFourth, .oneTwentyEighth,
                         .twoFiftySixth:
                        flagShift = metrics.sp * 0.3
                    default:
                        flagShift = 0
                    }
                    let chordX = timedX() - flagShift
                    let chordNotes = chord.notes.map { note -> LayoutChordNote in
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
                        return LayoutChordNote(
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
                    voiceChordOutIndex[voiceIdx] = out.count
                    out.append(.chord(
                        notes: chordNotes,
                        duration: chord.duration,
                        stem: stem,
                        stemOrigin: CGPoint(x: chordX, y: staffMidY),
                        hasArpeggio: chord.arpeggio != nil,
                        arpeggioRawType: chord.arpeggio.flatMap(arpeggioSubtype),
                        isBeamed: false))
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
                    // Lyrics: emit below the staff, one line per verse.
                    for (verseIdx, syllable) in chord.lyrics.enumerated() {
                        guard !syllable.isEmpty else { continue }
                        let lyricsY = staffMidY + metrics.sp * 6
                            + CGFloat(verseIdx) * metrics.sp * 2.5
                        out.append(.textMark(
                            kind: .lyrics,
                            text: syllable,
                            origin: CGPoint(x: chordX, y: lyricsY)))
                    }
                    tickCursor += chord.duration.ticks(division: division)
                case .dynamic(let d):
                    // Dynamics sit below-left of the note they apply to
                    // (i.e. the next timed element at the current tick).
                    // Shift 1 sp left so the label doesn't overlap the
                    // following chord's notehead or stem.
                    let baseX = inHeader
                        ? headerSchedule.contentStartX
                        : timedX()
                    out.append(.textMark(
                        kind: .dynamic,
                        text: d.subtype,
                        origin: CGPoint(
                            x: baseX - metrics.sp,
                            y: staffMidY + metrics.sp * 4)))
                case .tempo(let t):
                    let bpm = Int((t.beatsPerSecond * 60.0).rounded())
                    // "♩" is Unicode U+2669, rendered in the system text font,
                    // not a SMuFL/Bravura glyph — do not migrate to a SMuFL
                    // codepoint without also switching the renderer's font.
                    let tempoX = inHeader
                        ? headerSchedule.contentStartX
                        : timedX()
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
                            : timedX())
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
                }
            }

            // Glissando emission pass: pair each glissando-bearing note
            // with the corresponding note (same index) in the next chord
            // of the same voice. Uses actual note origins (not stemOrigin)
            // so the line slopes between the two different pitches.
            let chordVoiceIndices = voiceChordOutIndex.keys.sorted()
            for (pairIdx, voiceIdx) in chordVoiceIndices.enumerated() {
                guard case .chord(let chord) = voice.elements[voiceIdx]
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
                guard case .chord(let fromNotes, _, _, _, _, _, _) =
                        out[fromOutIdx],
                      case .chord(let toNotes, _, _, _, _, _, _) =
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
                          case .chord(let n, _, _, _, _, _, _)
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
                          case .chord(let n, _, _, let so, _, _, _)
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
                                      let arp, let art, _) = out[outIdx]
                    else { continue }
                    out[outIdx] = .chord(
                        notes: n,
                        duration: d,
                        stem: groupDirection,
                        stemOrigin: CGPoint(
                            x: so.x, y: memberStemYs[i]),
                        hasArpeggio: arp,
                        arpeggioRawType: art,
                        isBeamed: true)
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
        let hasExplicitBar = out.contains {
            if case .barLine = $0 { true } else { false }
        }
        if !hasExplicitBar {
            out.append(.barLine(
                subtype: nil,
                origin: CGPoint(
                    x: width - metrics.sp / 2,
                    y: staffMidY)))
        }
        return (out, currentClef)
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
                              _, _, _) = out[outIdx]
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
                case .chord(_, _, _, let firstSO, _, _, _) = out[firstIdx],
                case .chord(_, _, _, let lastSO, _, _, _) = out[lastIdx]
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

        out.append(.tupletLabel(
            fromOrigin: CGPoint(x: fromX, y: fromY),
            toOrigin: CGPoint(x: toX, y: toY),
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

    private static func totalTicks(in voice: Voice, division: Int) -> Int {
        voice.elements.reduce(0) { acc, el in
            switch el {
            case .chord(let c):
                return acc + c.duration.ticks(division: division)
            case .rest(let r):
                return acc + r.duration.ticks(division: division)
            default: return acc
            }
        }
    }

    /// Find the x coordinate of the most recently emitted chord or rest
    /// in `elements`, for positioning attached marks like fermatas.
    private static func lastChordOrRestX(
        in elements: [LayoutElement]
    ) -> CGFloat? {
        for el in elements.reversed() {
            switch el {
            case .chord(_, _, _, let origin, _, _, _):
                return origin.x
            case .rest(_, let origin):
                return origin.x
            default: continue
            }
        }
        return nil
    }
}
#endif
