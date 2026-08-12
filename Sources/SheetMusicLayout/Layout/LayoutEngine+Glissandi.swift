// swiftlint:disable file_length
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    /// Resolved glissando line: an absolute-coords pair ready to attach
    /// to a layout system (coordinates are system-absolute; the attach
    /// pass converts them to system-local). Mirrors `TiePair` in
    /// `LayoutEngine+Ties.swift`.
    ///
    /// Insets (the "start past the from-notehead, end before the
    /// to-notehead" 0.8 sp margin) are NOT applied here — they're
    /// applied at attach time so the cross-system slope interpolation
    /// in `attachGlissandi` works off the raw note origins.
    struct GlissandoPair: Equatable {
        let fromOrigin: CGPoint
        let toOrigin: CGPoint
        let wavy: Bool
        let text: String?
        /// Staff both endpoints share (a glissando never crosses
        /// staves). Lets `attachGlissandi` look up each system's
        /// per-staff origin via `LayoutSystem.flatIndex(for:)` to
        /// compute a staff-relative (pitch-space) slope instead of a
        /// system-local or document-absolute one.
        let staff: StaffAddress
    }

    /// Walk every staff/measure/voice/chord in `score` and pair each
    /// glissando-bearing note with the note it sweeps into. Unlike the
    /// old placement-time pass (which only looked within the CURRENT
    /// measure), this scans forward across measure boundaries — a
    /// glissando on the last chord of a measure now correctly finds its
    /// target in the next measure of the same voice.
    ///
    /// A chord counts as a pairing candidate only when it carries real
    /// notes — `VoiceElement` represents a rest as a `.chord` with an
    /// empty `notes` array (see `VoiceElement` doc comment), and those
    /// are skipped along with every non-chord element type.
    ///
    /// Returns path-based `NoteID` pairs (not resolved coordinates) so
    /// this function needs only the `Score`, not a laid-out document —
    /// coordinate resolution happens separately in `resolveGlissandi`.
    static func collectGlissandi(
        score: Score,
    ) -> [(from: NoteID, to: NoteID, wavy: Bool, text: String?)] {
        var results: [(from: NoteID, to: NoteID, wavy: Bool, text: String?)] = []
        for (address, staff) in score.allStaves {
            for (measureIndex, measure) in staff.measures.enumerated() {
                for (voiceIndex, voice) in measure.voices.enumerated() {
                    for (elementIndex, element) in voice.elements.enumerated() {
                        guard case let .chord(chord) = element,
                              !chord.notes.isEmpty
                        else { continue }
                        for (noteIndex, note) in chord.notes.enumerated() {
                            guard let gliss = note.glissando else { continue }
                            guard let target = nextChordLocation(
                                in: staff,
                                afterMeasure: measureIndex,
                                voiceIndex: voiceIndex,
                                afterElement: elementIndex,
                            ) else { continue }
                            // Same note index as the source, falling back
                            // to the target chord's LAST note when it has
                            // fewer notes (parity with the old
                            // `+Placement.swift` pairing).
                            let targetNoteIndex = target.chord.notes.indices
                                .contains(noteIndex)
                                ? noteIndex
                                : target.chord.notes.count - 1
                            let from = NoteID(
                                staff: address,
                                measureIndex: measureIndex,
                                voiceIndex: voiceIndex,
                                elementIndex: elementIndex,
                                noteIndexInChord: noteIndex,
                            )
                            let to = NoteID(
                                staff: address,
                                measureIndex: target.measureIndex,
                                voiceIndex: voiceIndex,
                                elementIndex: target.elementIndex,
                                noteIndexInChord: targetNoteIndex,
                            )
                            results.append((
                                from: from,
                                to: to,
                                wavy: gliss.visualType == .wavy,
                                text: gliss.text,
                            ))
                        }
                    }
                }
            }
        }
        return results
    }

    /// Scan forward for the next real chord (non-empty `notes`) in
    /// `voiceIndex`, starting immediately after `elementIndex` in
    /// `afterMeasure`. Rests (empty-note chords) and non-chord elements
    /// are skipped. When the current measure is exhausted, continues
    /// into subsequent measures of the same staff; measures where
    /// `voiceIndex` doesn't exist (voice absent) are skipped entirely.
    private static func nextChordLocation(
        in staff: Staff,
        afterMeasure: Int,
        voiceIndex: Int,
        afterElement: Int,
    ) -> (measureIndex: Int, elementIndex: Int, chord: Chord)? {
        if staff.measures.indices.contains(afterMeasure) {
            let voices = staff.measures[afterMeasure].voices
            if voices.indices.contains(voiceIndex) {
                let elements = voices[voiceIndex].elements
                var idx = afterElement + 1
                while idx < elements.count {
                    if case let .chord(chord) = elements[idx], !chord.notes.isEmpty {
                        return (afterMeasure, idx, chord)
                    }
                    idx += 1
                }
            }
        }
        var measureIndex = afterMeasure + 1
        while measureIndex < staff.measures.count {
            let voices = staff.measures[measureIndex].voices
            if voices.indices.contains(voiceIndex) {
                for (idx, element) in voices[voiceIndex].elements.enumerated() {
                    if case let .chord(chord) = element, !chord.notes.isEmpty {
                        return (measureIndex, idx, chord)
                    }
                }
            }
            measureIndex += 1
        }
        return nil
    }

    /// Resolve `collectGlissandi`'s path-based pairs against the
    /// laid-out `document`, producing absolute-coordinate pairs ready
    /// for `attachGlissandi`. A single walk over every system builds a
    /// `NoteID → absolute origin` map restricted to the note IDs the
    /// collected pairs actually need, then each pair looks up its two
    /// endpoints. Pairs whose endpoint isn't found (shouldn't happen
    /// for a well-formed document) are dropped.
    static func resolveGlissandi(
        for document: LayoutDocument,
        score: Score,
    ) -> [GlissandoPair] {
        let raw = collectGlissandi(score: score)
        guard !raw.isEmpty else { return [] }

        var needed: Set<NoteID> = []
        for item in raw {
            needed.insert(item.from)
            needed.insert(item.to)
        }

        var origins: [NoteID: CGPoint] = [:]
        for system in document.systems {
            for measure in system.measures {
                for el in measure.elements {
                    guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _) = el
                    else { continue }
                    for n in notes where needed.contains(n.noteID) {
                        // Origin-only (no `mirrorDx`), matching the
                        // coordinates the old same-measure emission used
                        // — keeps same-measure glissando geometry
                        // unchanged by this refactor.
                        origins[n.noteID] = CGPoint(
                            x: system.origin.x + measure.origin.x + n.origin.x,
                            y: system.origin.y + measure.origin.y + n.origin.y,
                        )
                    }
                }
            }
        }

        return raw.compactMap { item in
            guard let fromOrigin = origins[item.from],
                  let toOrigin = origins[item.to]
            else { return nil }
            return GlissandoPair(
                fromOrigin: fromOrigin, toOrigin: toOrigin,
                wavy: item.wavy, text: item.text,
                staff: item.from.staff,
            )
        }
    }

    /// Attach resolved glissando pairs to their systems' `spanners`.
    /// Mirrors `attachTies`: same-system pairs get one line inset at
    /// both ends; cross-system pairs are split into a BEGIN segment
    /// (to the source system's right edge) and an END segment (from
    /// near the target system's first content) so the line reads as a
    /// visual continuation across the break.
    static func attachGlissandi( // swiftlint:disable:this function_body_length
        to systems: [LayoutSystem],
        pairs: [GlissandoPair],
        metrics: StaffMetrics,
    ) -> [LayoutSystem] {
        guard !pairs.isEmpty else { return systems }

        let inset = metrics.sp * 0.8
        var extraPerSystem: [[LayoutElement]] =
            Array(repeating: [], count: systems.count)

        for pair in pairs {
            let fromSysIdx = systemIndex(for: pair.fromOrigin.y, in: systems)
            let toSysIdx = systemIndex(for: pair.toOrigin.y, in: systems)
            if fromSysIdx == toSysIdx, let idx = fromSysIdx {
                let sys = systems[idx]
                let fromLocal = CGPoint(
                    x: pair.fromOrigin.x - sys.origin.x + inset,
                    y: pair.fromOrigin.y - sys.origin.y,
                )
                let toLocal = CGPoint(
                    x: pair.toOrigin.x - sys.origin.x - inset,
                    y: pair.toOrigin.y - sys.origin.y,
                )
                // Degenerate/very tight spacing after insets — skip
                // rather than draw an inverted line.
                guard toLocal.x > fromLocal.x else { continue }
                extraPerSystem[idx].append(.glissandoLine(
                    fromOrigin: fromLocal,
                    toOrigin: toLocal,
                    wavy: pair.wavy,
                    text: pair.text,
                ))
            } else if let from = fromSysIdx, let to = toSysIdx {
                // Note: only the immediately-adjacent-system case is
                // handled below. A glissando spanning THREE OR MORE
                // systems (fully-covered middle systems) would need an
                // additional full-width segment per intervening system;
                // in practice a glissando's target is always the very
                // next chord, so it can cross at most one system break.
                let fromSys = systems[from]
                let toSys = systems[to]
                let fromLocalX = pair.fromOrigin.x - fromSys.origin.x
                let fromLocalY = pair.fromOrigin.y - fromSys.origin.y
                let toLocalX = pair.toOrigin.x - toSys.origin.x
                let toLocalY = pair.toOrigin.y - toSys.origin.y
                // END anchor: same `firstContentX` approximation of
                // MuseScore's `firstNoteRestSegmentX` that `attachTies`
                // uses, so the incoming segment doesn't cross the
                // synthesised clef/key signature at the system head.
                let firstContent = firstContentX(in: toSys)
                let endStartX = min(
                    max(firstContent - metrics.sp * 0.5, toLocalX - metrics.sp * 4),
                    toLocalX - metrics.sp,
                )

                // BEGIN stub: extend rightward into the right page
                // margin so it is long enough to (a) read as a line
                // and (b) clear the "gliss." label's width gate (the
                // `.glissando` text style is ≈3.5–4 sp wide at any
                // staff size; a 2.4 sp stub silently dropped the label
                // under `if textWidth < length`). Never move the left
                // end left of the source notehead.
                let beginEdgeX = fromSys.size.width - metrics.sp * 0.5
                let beginFrom = CGPoint(x: fromLocalX + inset, y: fromLocalY)
                let beginToX = min(
                    max(beginEdgeX, beginFrom.x + metrics.sp * 5),
                    fromSys.size.width + metrics.sp * 2,
                )

                // END stub: guarantee a minimum visible run reaching
                // the target note — the old `endStartX` alone shrank to
                // ≈0.2 sp (`sp - inset`) whenever the target was the
                // system's very first note, making the incoming line
                // effectively invisible.
                let endFromX = min(endStartX, (toLocalX - inset) - metrics.sp * 2.5)

                // Vertical delta in STAFF-RELATIVE (pitch) space: each
                // note's offset from ITS OWN staff's origin, looked up
                // via `LayoutSystem.flatIndex(for:)`. This is
                // independent of how the two systems are justified, so
                // it gives a genuine directional cue toward the target
                // pitch. Two earlier attempts got this wrong and are
                // FORBIDDEN here: (1) a document-ABSOLUTE Δy folds in
                // the full system-to-system vertical stride and shoots
                // one endpoint hundreds of points outside its own
                // system; (2) a SYSTEM-LOCAL Δy (`toLocalY -
                // fromLocalY`) ignores that systems are justified
                // independently — a staff's origin AND its inter-staff
                // spacing differ per system, so on a_perfect_sky the
                // glissando's staff sits at y≈1001 in one system and
                // y≈413 in the next, sloping the "continuous" stub 500
                // pt up through every staff above it. Both plunged the
                // line across staves. As belt-and-suspenders even the
                // correct pitch-space delta is hard-clamped to ±1.5 sp
                // per segment — inter-staff gaps are ≥6 sp, so this
                // makes entering a neighbouring staff impossible.
                var dyBegin: CGFloat = 0
                var dyEnd: CGFloat = 0
                if let ffi = fromSys.flatIndex(for: pair.staff),
                   let tfi = toSys.flatIndex(for: pair.staff)
                {
                    let deltaY = (toLocalY - toSys.staffOrigins[tfi].y)
                        - (fromLocalY - fromSys.staffOrigins[ffi].y)
                    if abs(deltaY) >= metrics.sp * 0.5 { // near-unison: stay horizontal
                        let beginRun = beginToX - beginFrom.x
                        let endRun = (toLocalX - inset) - endFromX
                        let total = beginRun + endRun
                        if total > 0 {
                            let maxDrop = metrics.sp * 1.5
                            dyBegin = max(-maxDrop, min(maxDrop, deltaY * beginRun / total))
                            dyEnd = max(-maxDrop, min(maxDrop, deltaY * endRun / total))
                        }
                    }
                }

                let beginTo = CGPoint(x: beginToX, y: fromLocalY + dyBegin)
                if beginTo.x > beginFrom.x {
                    extraPerSystem[from].append(.glissandoLine(
                        fromOrigin: beginFrom,
                        toOrigin: beginTo,
                        wavy: pair.wavy,
                        text: pair.text,
                    ))
                }

                let endFrom = CGPoint(x: endFromX, y: toLocalY - dyEnd)
                let endTo = CGPoint(x: toLocalX - inset, y: toLocalY)
                if endTo.x > endFrom.x {
                    extraPerSystem[to].append(.glissandoLine(
                        fromOrigin: endFrom,
                        toOrigin: endTo,
                        wavy: pair.wavy,
                        // Only the BEGIN segment carries the label —
                        // otherwise "gliss." would print twice.
                        text: nil,
                    ))
                }
            }
        }

        return systems.enumerated().map { idx, system in
            system.addingSpanners(extraPerSystem[idx])
        }
    }
}
