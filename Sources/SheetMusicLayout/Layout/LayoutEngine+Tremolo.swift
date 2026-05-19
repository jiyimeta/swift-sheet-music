#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    /// Extra stem length needed to fit a chord's tremolo bars between
    /// the notehead and the flag without overlap, for UNBEAMED flagged
    /// chords. Returns 0 when no extension is needed:
    ///  * no tremolo → 0.
    ///  * non-flagged duration (whole/half/quarter) → 0 (the natural
    ///    stem is long enough; bars sit at midstem).
    /// Otherwise returns `barBlockHeight - 0.5 sp`, derived from the
    /// constraint that the bar block (placed flush against the flag
    /// with a small gap) must clear the notehead by ~0.5 sp:
    ///
    ///     stem ≥ flagHeight + barBeamGap + barBlock + noteheadGap
    ///          ≈ 2 + 0.5 + barBlock + 0.5
    ///          = 3 + barBlock
    ///   defaultStemLen ≈ 3.5 sp ⇒ extra = max(0, barBlock - 0.5)
    ///
    /// BEAMED chords don't use this — the beam pass (`Placement`
    /// Phase 4) leaves the beam at its natural Y and the tremolo
    /// reanchor pass slots bars below the beam stack instead.
    static func tremoloStemExtension(
        for chord: Chord,
        metrics: StaffMetrics,
    ) -> CGFloat {
        guard let trem = chord.tremolo,
              isFlaggedDuration(chord.duration)
        else { return 0 }
        let blockH = barBlockHeight(
            barCount: Int(trem.subtype.rawValue),
            metrics: metrics,
        )
        return max(0, blockH - metrics.sp * 0.5)
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

    /// Bar block centre for a `.single` tremolo on an UNBEAMED chord.
    /// FLAGGED durations bias toward the stem tip (with `flagHeight +
    /// barBeamGap` clearance); UNFLAGGED durations (quarter / half)
    /// centre at midstem. Beamed chords are re-anchored later by
    /// `reanchorBeamedTremoloBars`.
    private static func singleTremoloCenter( // swiftlint:disable:this function_parameter_count
        stemTopY: CGFloat,
        stemBottomY: CGFloat,
        stemX: CGFloat,
        stem: StemDirection,
        duration: NoteDuration,
        barCount: Int,
        metrics: StaffMetrics,
    ) -> CGPoint {
        let stemTipY = (stem == .up) ? stemTopY : stemBottomY
        let noteSideY = (stem == .up) ? stemBottomY : stemTopY
        let centerY: CGFloat
        if isFlaggedDuration(duration) {
            let blockH = barBlockHeight(
                barCount: barCount, metrics: metrics,
            )
            // flagHeight ≈ 2 sp covers flag8thUp / flag16thUp / …
            // (Bravura). Bar block sits flush past the flag with a
            // `barBeamGap` of `sp * 0.5`.
            let flagHeight: CGFloat = metrics.sp * 2.0
            let gap: CGFloat = metrics.sp * 0.5
            let dy = flagHeight + gap + blockH / 2
            centerY = stemTipY + (stem == .up ? 1 : -1) * dy
        } else {
            centerY = (stemTipY + noteSideY) / 2
        }
        return CGPoint(x: stemX, y: centerY)
    }

    /// True when `dur` would be drawn with a flag (8th or shorter).
    static func isFlaggedDuration(_ dur: NoteDuration) -> Bool {
        switch dur {
        case .eighth, .sixteenth, .thirtySecond,
             .sixtyFourth, .oneTwentyEighth, .twoFiftySixth:
            true
        default:
            false
        }
    }

    /// Vertical extent of the BEAM stack at a beamLevel-`level` chord
    /// — every primary + secondary beam visible at that chord's stem
    /// position. Matches `BeamRenderer.draw`'s `beamThickness +
    /// beamGap` stacking convention.
    static func beamStackHeight(
        beamLevel: Int, metrics: StaffMetrics,
    ) -> CGFloat {
        guard beamLevel > 0 else { return 0 }
        let thickness = metrics.sp * 0.5
        let gap = metrics.sp * 0.3
        return CGFloat(beamLevel) * thickness
            + CGFloat(beamLevel - 1) * gap
    }

    /// Re-anchor the `.tremoloBars` element that follows the chord at
    /// `outIdx` so its bar block sits past the BEAM STACK
    /// (`beamStackHeight(level) + barBeamGap` from `beamY`), matching
    /// MuseScore engraving. Called from the beam pass once each
    /// member's actual `beamY` and beam level are known.
    ///
    /// Search range: the element immediately after the chord up to the
    /// next non-decoration element (we stop at the next `.chord` /
    /// `.note` / `.rest` to avoid leaking into the next member's
    /// decorations). `.between` anchors are left alone — they bridge
    /// two stems and a tweak here would misalign with the partner.
    static func reanchorBeamedTremoloBars( // swiftlint:disable:this function_parameter_count
        in out: inout [LayoutElement],
        afterChordAt outIdx: Int,
        beamY: CGFloat,
        stem: StemDirection,
        beamLevel: Int,
        metrics: StaffMetrics,
    ) {
        guard outIdx + 1 < out.count else { return }
        for j in (outIdx + 1) ..< out.count {
            switch out[j] {
            case .chord, .note, .rest:
                return // belongs to a different chord
            case let .tremoloBars(.single(prevCenter), barCount):
                let beamH = beamStackHeight(
                    beamLevel: beamLevel, metrics: metrics,
                )
                let blockH = barBlockHeight(
                    barCount: barCount, metrics: metrics,
                )
                let gap = metrics.sp * 0.5
                let dy = beamH + gap + blockH / 2
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
        duration: NoteDuration,
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
            let center = singleTremoloCenter(
                stemTopY: top.y, stemBottomY: bottom.y,
                stemX: top.x, stem: stem,
                duration: duration, barCount: barCount,
                metrics: metrics,
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
