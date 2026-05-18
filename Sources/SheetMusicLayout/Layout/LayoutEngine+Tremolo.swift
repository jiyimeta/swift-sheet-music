import CoreGraphics
import SheetMusicCore

@available(macOS 15.0, *)
extension LayoutEngine {
    /// Extra stem length needed to fit a chord's tremolo bars between
    /// the notehead and the flag/beam without overlap. Returns 0 when
    /// no extension is needed:
    ///  * no tremolo → 0.
    ///  * beamed chord → 0 (the beam is fixed by the beam pass; bars
    ///    sit between notehead and beam without moving either).
    ///  * non-flagged duration (whole/half/quarter) → 0 (the natural
    ///    stem is long enough to clear bars at midstem).
    /// Otherwise returns `(barCount - 1) * spacing + thickness`, the
    /// vertical extent of the bar stack — pushing the stem tip past
    /// where the flag would collide with the topmost bar.
    static func tremoloStemExtension(
        for chord: Chord,
        isBeamed: Bool,
        metrics: StaffMetrics,
    ) -> CGFloat {
        guard let trem = chord.tremolo, !isBeamed else { return 0 }
        switch chord.duration {
        case .eighth, .sixteenth, .thirtySecond,
             .sixtyFourth, .oneTwentyEighth, .twoFiftySixth:
            break
        default:
            return 0
        }
        let bars = Int(trem.subtype.rawValue) // 1, 2, or 3
        let thickness = metrics.sp * 0.5 // matches beam thickness
        let spacing = metrics.sp * 0.8 // thickness + 0.3 sp gap
        return CGFloat(bars - 1) * spacing + thickness
    }

    /// Build a `.tremoloBars` element for a chord carrying `tremolo`.
    /// Returns `nil` when a `.between` tremolo has no follower chord
    /// in the voice (e.g. the start chord is the voice's last element
    /// — an invalid score shape that the decoder normally prevents).
    ///
    /// Geometry mirrors MuseScore's standalone-stem convention used
    /// elsewhere in `LayoutEngine+Placement`: the stem reaches
    /// `defaultStemLength` past the far notehead. For stem-up the
    /// far note is the lowest; for stem-down the far note is the
    /// highest. The bars themselves are placed at the stem midpoint
    /// in v1 — the renderer (Task 1.8) is responsible for the slant.
    static func makeTremoloBarsElement( // swiftlint:disable:this function_parameter_count
        tremolo: Tremolo,
        chordX: CGFloat,
        chordNotes: [LayoutChordNote],
        stem: StemDirection,
        stemExtension: CGFloat,
        staffMidY: CGFloat,
        metrics: StaffMetrics,
        currentClef: NotatedClef,
        currentVoiceElements: [VoiceElement],
        currentVoiceElemIdx: Int,
        currentTick: Int,
        measureDuration: Fraction,
        division: Int,
        timedX: (Int) -> CGFloat,
    ) -> LayoutElement? {
        let (top, bottom) = stemEndpoints(
            chordX: chordX, chordNotes: chordNotes,
            stem: stem, stemExtension: stemExtension,
            staffMidY: staffMidY, metrics: metrics,
        )
        let barCount = Int(tremolo.subtype.rawValue)
        switch tremolo.span {
        case .single:
            return .tremoloBars(
                anchor: .single(stemTop: top, stemBottom: bottom),
                barCount: barCount,
            )
        case .between:
            guard let followerCtx = followerChordContext(
                in: currentVoiceElements,
                startingAfter: currentVoiceElemIdx,
                startTick: currentTick,
                measureDuration: measureDuration,
                division: division,
                timedX: timedX,
            ) else { return nil }
            let followerNotes = preliminaryFollowerNotes(
                followerCtx.chord,
                atX: followerCtx.x,
                staffMidY: staffMidY,
                metrics: metrics,
                clef: currentClef,
            )
            let followerStem = StemDirectionRule
                .direction(for: followerNotes.map(\.step))
            // For .between tremolo placement we mirror the start
            // chord's extension on the follower so the bar geometry
            // bridges two stems of equal length. The follower's own
            // chord.tremolo was cleared by the decoder's second pass,
            // so we can't ask `tremoloStemExtension` for it.
            let (fTop, fBot) = stemEndpoints(
                chordX: followerCtx.x,
                chordNotes: followerNotes,
                stem: followerStem,
                stemExtension: stemExtension,
                staffMidY: staffMidY,
                metrics: metrics,
            )
            let leftMid = CGPoint(
                x: (top.x + bottom.x) / 2,
                y: (top.y + bottom.y) / 2,
            )
            let rightMid = CGPoint(
                x: (fTop.x + fBot.x) / 2,
                y: (fTop.y + fBot.y) / 2,
            )
            return .tremoloBars(
                anchor: .between(
                    leftStemMid: leftMid, rightStemMid: rightMid,
                ),
                barCount: barCount,
            )
        }
    }

    /// Approximate stem endpoints for a chord using the standalone
    /// `defaultStemLength` heuristic. The beam pass may later relocate
    /// the beam-side endpoint, but tremolo geometry is computed
    /// pre-beam (matching the pre-beam emission order in
    /// `placeMeasureElements`).
    ///
    /// X must match `StemRenderer`'s `stemAttachDx = sp * 0.59`
    /// (Bravura `noteheadBlack` `stemUpSE.x` / `stemDownNW.x` anchor),
    /// so the bars centre on the stem rather than the notehead.
    private static func stemEndpoints( // swiftlint:disable:this function_parameter_count
        chordX: CGFloat,
        chordNotes: [LayoutChordNote],
        stem: StemDirection,
        stemExtension: CGFloat,
        staffMidY: CGFloat,
        metrics: StaffMetrics,
    ) -> (top: CGPoint, bottom: CGPoint) {
        let xs = chordNotes.map(\.origin.x)
        let ys = chordNotes.map(\.origin.y)
        let topNoteY = ys.min() ?? staffMidY
        let botNoteY = ys.max() ?? staffMidY
        let stemAttachDx = metrics.sp * 0.59
        switch stem {
        case .up:
            let stemX = (xs.max() ?? chordX) + stemAttachDx
            let stemTipY = botNoteY - metrics.defaultStemLength
                - stemExtension
            return (
                CGPoint(x: stemX, y: stemTipY),
                CGPoint(x: stemX, y: botNoteY),
            )
        case .down:
            let stemX = (xs.min() ?? chordX) - stemAttachDx
            let stemTipY = topNoteY + metrics.defaultStemLength
                + stemExtension
            return (
                CGPoint(x: stemX, y: topNoteY),
                CGPoint(x: stemX, y: stemTipY),
            )
        }
    }

    /// Walk the voice forwards from the start chord's index to find
    /// the next chord (skipping non-chord siblings), advancing the
    /// running tick by any `.locationShift` deltas encountered.
    private static func followerChordContext( // swiftlint:disable:this function_parameter_count
        in elements: [VoiceElement],
        startingAfter startIdx: Int,
        startTick: Int,
        measureDuration: Fraction,
        division: Int,
        timedX: (Int) -> CGFloat,
    ) -> (chord: Chord, x: CGFloat)? {
        // The start chord's own duration moves the cursor forward by
        // its tick count before any follower can begin.
        guard startIdx < elements.count,
              case let .chord(startChord) = elements[startIdx]
        else { return nil }
        var tick = startTick + startChord.duration
            .resolved(in: measureDuration).ticks(division: division)
        for j in (startIdx + 1) ..< elements.count {
            switch elements[j] {
            case let .chord(follower) where !follower.notes.isEmpty:
                return (follower, timedX(tick))
            case let .chord(rest):
                // Rest-shaped empty chord; advance the cursor and
                // keep searching for the sounding follower.
                tick += rest.duration
                    .resolved(in: measureDuration).ticks(division: division)
            case let .locationShift(delta):
                tick += delta.ticks(division: division)
            default:
                continue
            }
        }
        return nil
    }

    /// Build a minimal `LayoutChordNote` list for the follower chord
    /// in a `.between` tremolo. Only the `step` and `origin.y` fields
    /// are read by `stemEndpoints`; the rest are defaulted because
    /// these values do not enter the layout output — they exist solely
    /// to derive the follower's stem extent for the tremolo bars.
    private static func preliminaryFollowerNotes(
        _ chord: Chord,
        atX x: CGFloat,
        staffMidY: CGFloat,
        metrics: StaffMetrics,
        clef: NotatedClef,
    ) -> [LayoutChordNote] {
        chord.notes.map { note in
            // Reuse the diatonic formula directly with the active
            // clef. The follower chord's noteheads keep the start
            // chord's clef context (mid-tremolo clef changes are not
            // valid notation), so this is exact for valid scores.
            let step = PitchStaffPosition.step(
                midiPitch: note.pitch, tpc: note.tpc,
                clef: clef,
            ).step
            let y = staffMidY - CGFloat(step) * metrics.sp / 2
            return LayoutChordNote(
                noteID: NoteID(
                    staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                    measureIndex: 0,
                    voiceIndex: 0,
                    elementIndex: 0,
                    noteIndexInChord: 0,
                ),
                step: step,
                accidental: nil,
                origin: CGPoint(x: x, y: y),
                tieForward: nil,
                tieBack: nil,
                hasGlissando: false,
            )
        }
    }
}
