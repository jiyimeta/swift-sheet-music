import CoreGraphics
import SheetMusicCore

@available(macOS 15.0, *)
extension LayoutEngine {
    /// Extra stem length needed to fit a chord's tremolo bars between
    /// the notehead and the flag/beam without overlap.
    ///
    /// Returns 0 when no extension is needed:
    ///  * no tremolo → 0.
    ///  * non-flagged duration (whole/half/quarter) → 0 (the natural
    ///    stem is long enough to clear bars at midstem).
    /// Otherwise returns `(barCount - 1) * spacing + thickness`, the
    /// vertical extent of the bar stack — pushing the stem tip past
    /// where the flag/beam would collide with the topmost bar.
    ///
    /// For UNBEAMED chords the caller threads this into
    /// `LayoutElement.chord.stemExtension` and the stem renderer
    /// lengthens the stem directly. For BEAMED chords the beam pass
    /// (`LayoutEngine+Placement` Phase 4) instead shifts the beam line
    /// by the max group extension — so all members of a beam group
    /// share a consistently lifted beam.
    static func tremoloStemExtension(
        for chord: Chord,
        metrics: StaffMetrics,
    ) -> CGFloat {
        guard let trem = chord.tremolo else { return 0 }
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

    /// Vertical extent of a `barCount`-bar tremolo block at the
    /// project's bar thickness / spacing (matches `beamThickness` /
    /// `beamSpacing`).
    static func barBlockHeight(
        barCount: Int, metrics: StaffMetrics,
    ) -> CGFloat {
        let thickness = metrics.sp * 0.5 // matches beam thickness
        let spacing = metrics.sp * 0.8 // thickness + 0.3 sp gap
        return CGFloat(barCount - 1) * spacing + thickness
    }

    /// Re-anchor the `.tremoloBars` element that follows the chord at
    /// `outIdx` so its bar block sits just past the beam (with a
    /// `barBeamGap` of `sp * 0.5`), matching MuseScore engraving.
    /// Called from the beam pass once each member's actual `beamY` is
    /// known.
    ///
    /// Search range: the element immediately after the chord up to the
    /// next non-decoration element (we stop at the next `.chord` /
    /// `.note` / `.rest` to avoid leaking into the next member's
    /// decorations). `.between` anchors are left alone — they bridge
    /// two stems and a tweak here would misalign with the partner.
    static func reanchorBeamedTremoloBars(
        in out: inout [LayoutElement],
        afterChordAt outIdx: Int,
        beamY: CGFloat,
        stem: StemDirection,
        metrics: StaffMetrics,
    ) {
        guard outIdx + 1 < out.count else { return }
        for j in (outIdx + 1) ..< out.count {
            switch out[j] {
            case .chord, .note, .rest:
                return // belongs to a different chord
            case let .tremoloBars(.single(prevCenter), barCount):
                let blockH = barBlockHeight(
                    barCount: barCount, metrics: metrics,
                )
                let gap = metrics.sp * 0.5
                let dy = gap + blockH / 2
                let centerY = stem == .up ? beamY + dy : beamY - dy
                out[j] = .tremoloBars(
                    anchor: .single(
                        center: CGPoint(x: prevCenter.x, y: centerY),
                    ),
                    barCount: barCount,
                )
                return
            default:
                continue
            }
        }
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
            // Pre-beam estimate: bar block at midpoint of the stem.
            // If the chord later gets beamed, the beam pass re-anchors
            // this via `reanchorBeamedTremoloBars` to sit near the
            // shifted beam instead.
            let center = CGPoint(
                x: top.x, y: (top.y + bottom.y) / 2,
            )
            return .tremoloBars(
                anchor: .single(center: center),
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
