#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    /// One resolved legacy bend: the absolute origin of the notehead it
    /// hangs off, the staff that notehead belongs to (needed for the
    /// staff-top clamp), and the curve itself.
    struct ResolvedLegacyBend: Equatable {
        let origin: CGPoint
        let staff: StaffAddress
        let bend: LegacyBend
    }

    /// Walk every staff/measure/voice/chord in `score` and collect the
    /// notes carrying a legacy `<Bend>`. Mirrors `collectGuitarBends`,
    /// minus the pairing: a legacy bend is a note-LOCAL decoration with
    /// no second anchor, so there is nothing to look forward to.
    ///
    /// Curves with fewer than two points are dropped here. MuseScore's
    /// draw loop runs `for (pt = 0; pt < n - 1; ++pt)` and emits nothing
    /// for `n < 2`; the decoder can hand us such a curve from a
    /// degenerate file, and carrying it further would put an empty
    /// element into the skyline.
    ///
    /// Grace chords are not walked — same v1 policy as guitar bends
    /// (`Chord.graceNotesBefore` / `graceNotesAfter` are not
    /// `voice.elements`, and grace notes carry no `NoteID` in the layout
    /// origin map).
    static func collectLegacyBends(score: Score) -> [(NoteID, LegacyBend)] {
        var results: [(NoteID, LegacyBend)] = []
        for (address, staff) in score.allStaves {
            for (measureIndex, measure) in staff.measures.enumerated() {
                for (voiceIndex, voice) in measure.voices.enumerated() {
                    for (elementIndex, element) in voice.elements.enumerated() {
                        guard case let .chord(chord) = element else { continue }
                        for (noteIndex, note) in chord.notes.enumerated() {
                            guard let bend = note.legacyBend,
                                  bend.points.count >= 2
                            else { continue }
                            results.append((
                                NoteID(
                                    staff: address,
                                    measureIndex: measureIndex,
                                    voiceIndex: voiceIndex,
                                    elementIndex: elementIndex,
                                    noteIndexInChord: noteIndex,
                                ),
                                bend,
                            ))
                        }
                    }
                }
            }
        }
        return results
    }

    /// Resolve `collectLegacyBends`' path-based notes against the
    /// laid-out `document`, the same single walk `resolveGuitarBends`
    /// does. Notes that aren't in the origin map are dropped silently —
    /// the v1 policy for anything hanging off a grace chord.
    ///
    /// No stem directions are collected: a legacy bend always draws
    /// above the note, whatever the stem does.
    static func resolveLegacyBends(
        for document: LayoutDocument,
        score: Score,
    ) -> [ResolvedLegacyBend] {
        let raw = collectLegacyBends(score: score)
        guard !raw.isEmpty else { return [] }

        let needed = Set(raw.map(\.0))
        var origins: [NoteID: CGPoint] = [:]
        for system in document.systems {
            for measure in system.measures {
                for el in measure.elements {
                    guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _) = el
                    else { continue }
                    for n in notes where needed.contains(n.noteID) {
                        origins[n.noteID] = CGPoint(
                            x: system.origin.x + measure.origin.x + n.origin.x,
                            y: system.origin.y + measure.origin.y + n.origin.y,
                        )
                    }
                }
            }
        }

        return raw.compactMap { noteID, bend in
            guard let origin = origins[noteID] else { return nil }
            return ResolvedLegacyBend(
                origin: origin, staff: noteID.staff, bend: bend,
            )
        }
    }

    /// Attach resolved legacy bends to their systems' `spanners`.
    ///
    /// The geometry frame conversion, per bend:
    ///
    /// * `LegacyBendGeometry.shape` works in MuseScore's note-pos frame —
    ///   origin at the notehead's LEFT edge horizontally but its vertical
    ///   CENTRE. Our note origins are the centre on BOTH axes, so the
    ///   whole shape shifts by `(noteLocal.x - 0.5 * noteheadWidth,
    ///   noteLocal.y)`. (Same conversion `GuitarBendGeometry`'s
    ///   `angularAnchorOffset` documents, where the term cancels instead.)
    /// * `notePosY` is the note's distance BELOW its staff's top line,
    ///   clamped at 0 (`notePos.ry() = std::max(notePos.y(), 0.0)`,
    ///   `tlayout.cpp:1265`), so a note above the staff still rises to
    ///   2 sp over its own head rather than diving back toward the staff.
    static func attachLegacyBends(
        to systems: [LayoutSystem],
        resolved: [ResolvedLegacyBend],
        metrics: StaffMetrics,
    ) -> [LayoutSystem] {
        guard !resolved.isEmpty else { return systems }

        let sp = metrics.sp
        let noteWidth = GuitarBendGeometry.noteheadWidthSp * sp
        var extraPerSystem: [[LayoutElement]] =
            Array(repeating: [], count: systems.count)

        for item in resolved {
            guard let idx = systemIndex(for: item.origin.y, in: systems)
            else { continue }
            let system = systems[idx]
            guard let flat = system.flatIndex(for: item.staff),
                  system.staffOrigins.indices.contains(flat)
            else { continue }
            let noteLocal = CGPoint(
                x: item.origin.x - system.origin.x,
                y: item.origin.y - system.origin.y,
            )
            let notePosY = max(
                noteLocal.y - system.staffOrigins[flat].y, 0,
            )
            let shape = LegacyBendGeometry.shape(
                points: item.bend.points,
                noteWidth: noteWidth,
                notePosY: notePosY,
                sp: sp,
            ).translated(by: CGPoint(
                x: noteLocal.x - noteWidth / 2, y: noteLocal.y,
            ))
            guard !shape.pieces.isEmpty else { continue }
            extraPerSystem[idx].append(.legacyBend(shape: shape))
        }

        return systems.enumerated().map { idx, system in
            system.addingSpanners(extraPerSystem[idx])
        }
    }
}
