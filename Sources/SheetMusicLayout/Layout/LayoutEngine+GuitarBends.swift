#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    /// Resolved guitar bend: an absolute-coords pair ready to attach to a
    /// layout system. Structurally a `GlissandoPair` (see
    /// `LayoutEngine+Glissandi.swift`) with the bend's own discriminators
    /// instead of `wavy` / `text`.
    ///
    /// Anchor offsets are NOT applied here — they're applied at attach
    /// time, off the raw note origins, exactly as the glissando pass
    /// applies its insets there.
    struct GuitarBendPair: Equatable {
        let fromOrigin: CGPoint
        let toOrigin: CGPoint
        /// `true` when both endpoints are the SAME note — pre-bends and
        /// slight bends. The mirrored begin/end anchor offsets would
        /// then cross over each other, so the attach pass uses only the
        /// begin anchor and lets the bend degenerate to a tick.
        let sameNote: Bool
        /// `true` when the bend rises (end pitch at or above start),
        /// which is the side of the staff its vertex arcs toward.
        let up: Bool
        /// `true` for `GuitarBendType.slightBend`, which draws a fixed
        /// cubic hook rather than an angular polyline.
        let slight: Bool
    }

    /// One bend's endpoints as note PATHS, before coordinates are
    /// resolved. `collectGlissandi` returns a tuple for the same job;
    /// this needs five fields, one past SwiftLint's `large_tuple` limit.
    struct GuitarBendPairing: Equatable {
        let from: NoteID
        let to: NoteID
        let sameNote: Bool
        let up: Bool
        let slight: Bool
    }

    /// Walk every staff/measure/voice/chord in `score` and pair each
    /// bend-bearing note with the note the bend runs to. Mirrors
    /// `collectGlissandi`, including its rest/non-chord skipping and its
    /// forward scan across measure boundaries.
    ///
    /// Type-by-type pairing (C++:
    /// `GuitarBendLayout::layoutStandardStaff`,
    /// `rendering/score/guitarbendlayout.cpp:82`):
    ///
    /// * `.bend` and `.graceNoteBend` — the next real chord's note at the
    ///   same note index, falling back to that chord's last note.
    /// * `.preBend` and `.slightBend` — the same note (`to == from`).
    ///   MuseScore's pre-bend actually starts on a ghosted grace note,
    ///   but grace chords carry no `NoteID` in the layout origin map, so
    ///   v1 anchors it on the principal instead.
    /// * `.dive`, `.preDive`, `.dip`, `.scoop` — skipped. MuseScore
    ///   routes the whammy-bar types to `GuitarDiveLayout`, a separate
    ///   shape this package does not model yet.
    ///
    /// Bends whose source lives on a grace chord (which is where
    /// `guitarbend_prebend`'s and `guitarbend_release_twice`'s live) are
    /// never reached by this walk — `Chord.graceNotesBefore` /
    /// `graceNotesAfter` are not `voice.elements` — so they drop out
    /// here, one step earlier than `resolveGuitarBends`' unresolvable
    /// endpoints do. Both are the same v1 policy: drop silently.
    ///
    /// Returns path-based `NoteID` pairs, so this needs only the `Score`.
    static func collectGuitarBends(score: Score) -> [GuitarBendPairing] {
        var results: [GuitarBendPairing] = []
        for (address, staff) in score.allStaves {
            for (measureIndex, measure) in staff.measures.enumerated() {
                for (voiceIndex, voice) in measure.voices.enumerated() {
                    for (elementIndex, element) in voice.elements.enumerated() {
                        guard case let .chord(chord) = element,
                              !chord.notes.isEmpty
                        else { continue }
                        for (noteIndex, note) in chord.notes.enumerated() {
                            guard let bend = note.guitarBend else { continue }
                            let from = NoteID(
                                staff: address,
                                measureIndex: measureIndex,
                                voiceIndex: voiceIndex,
                                elementIndex: elementIndex,
                                noteIndexInChord: noteIndex,
                            )
                            guard let item = pairing(
                                bend: bend, note: note, from: from,
                                staff: staff, measureIndex: measureIndex,
                                voiceIndex: voiceIndex,
                                elementIndex: elementIndex,
                                noteIndex: noteIndex,
                            ) else { continue }
                            results.append(item)
                        }
                    }
                }
            }
        }
        return results
    }

    /// One note's bend → its `NoteID` pair, or `nil` when the type isn't
    /// laid out in v1 or no target chord exists. Split out of
    /// `collectGuitarBends` to keep both bodies short.
    private static func pairing(
        bend: GuitarBend,
        note: Note,
        from: NoteID,
        staff: Staff,
        measureIndex: Int,
        voiceIndex: Int,
        elementIndex: Int,
        noteIndex: Int,
    ) -> GuitarBendPairing? {
        switch bend.type {
        case .dive, .preDive, .dip, .scoop:
            return nil
        case .preBend, .slightBend:
            // Same-note pair: no target to look up, and no pitch delta,
            // so the bend arcs upward by convention.
            return GuitarBendPairing(
                from: from, to: from, sameNote: true, up: true,
                slight: bend.type == .slightBend,
            )
        case .bend, .graceNoteBend:
            guard let target = nextChordLocation(
                in: staff,
                afterMeasure: measureIndex,
                voiceIndex: voiceIndex,
                afterElement: elementIndex,
            ) else { return nil }
            // Same note index as the source, falling back to the target
            // chord's LAST note when it has fewer — parity with
            // `collectGlissandi`.
            let targetNoteIndex = target.chord.notes.indices.contains(noteIndex)
                ? noteIndex
                : target.chord.notes.count - 1
            let to = NoteID(
                staff: from.staff,
                measureIndex: target.measureIndex,
                voiceIndex: voiceIndex,
                elementIndex: target.elementIndex,
                noteIndexInChord: targetNoteIndex,
            )
            let endPitch = target.chord.notes[targetNoteIndex].pitch
            return GuitarBendPairing(
                from: from, to: to, sameNote: false,
                up: endPitch >= note.pitch, slight: false,
            )
        }
    }

    /// Resolve `collectGuitarBends`' path-based pairs against the
    /// laid-out `document`. A single walk over every system builds the
    /// `NoteID → absolute origin` map (the same walk `resolveGlissandi`
    /// does), then each pair looks up its endpoints. Pairs whose
    /// endpoints aren't in the map are dropped silently — the v1 policy
    /// for bends hanging off grace chords, which the map doesn't cover.
    static func resolveGuitarBends(
        for document: LayoutDocument,
        score: Score,
    ) -> [GuitarBendPair] {
        let raw = collectGuitarBends(score: score)
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
                        // Origin-only (no `mirrorDx`), matching
                        // `resolveGlissandi`.
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
            return GuitarBendPair(
                fromOrigin: fromOrigin, toOrigin: toOrigin,
                sameNote: item.sameNote, up: item.up, slight: item.slight,
            )
        }
    }

    /// Attach resolved guitar bends to their systems' `spanners`.
    ///
    /// Only same-system pairs are emitted. A bend's target is the
    /// immediately next chord, so it crosses a system break only when
    /// that chord opens the next system; splitting the polyline into
    /// BEGIN / END segments the way `attachGlissandi` does is deferred
    /// past v1, and such a pair is dropped rather than mis-drawn.
    static func attachGuitarBends(
        to systems: [LayoutSystem],
        pairs: [GuitarBendPair],
        metrics: StaffMetrics,
    ) -> [LayoutSystem] {
        guard !pairs.isEmpty else { return systems }

        let sp = metrics.sp
        var extraPerSystem: [[LayoutElement]] =
            Array(repeating: [], count: systems.count)

        for pair in pairs {
            let fromSysIdx = systemIndex(for: pair.fromOrigin.y, in: systems)
            let toSysIdx = systemIndex(for: pair.toOrigin.y, in: systems)
            guard fromSysIdx == toSysIdx, let idx = fromSysIdx else { continue }
            let sys = systems[idx]
            let noteLocal = CGPoint(
                x: pair.fromOrigin.x - sys.origin.x,
                y: pair.fromOrigin.y - sys.origin.y,
            )
            guard let element = element(
                for: pair, noteLocal: noteLocal, system: sys, sp: sp,
            ) else { continue }
            extraPerSystem[idx].append(element)
        }

        return systems.enumerated().map { idx, system in
            system.addingSpanners(extraPerSystem[idx])
        }
    }

    /// One resolved pair → its `LayoutElement.guitarBend`, in
    /// system-local coords, or `nil` when the anchors come out inverted.
    private static func element(
        for pair: GuitarBendPair,
        noteLocal: CGPoint,
        system: LayoutSystem,
        sp: CGFloat,
    ) -> LayoutElement? {
        if pair.slight {
            // Fixed cubic hook off the right of the notehead; no target
            // note is involved. C++: `layoutSlightBend`
            // (`guitarbendlayout.cpp:359`).
            let offset = GuitarBendGeometry.slightBendStartOffset(sp: sp)
            let start = CGPoint(
                x: noteLocal.x + offset.x, y: noteLocal.y + offset.y,
            )
            let end = GuitarBendGeometry.slightBendEnd(sp: sp)
            let control = GuitarBendGeometry.slightBendControl(sp: sp)
            return .guitarBend(
                fromOrigin: start,
                vertex: CGPoint(x: start.x + control.x, y: start.y + control.y),
                toOrigin: CGPoint(x: start.x + end.x, y: start.y + end.y),
                slight: true,
            )
        }

        let beginOffset = GuitarBendGeometry.angularAnchorOffset(
            sp: sp, up: pair.up, start: true,
        )
        let start = CGPoint(
            x: noteLocal.x + beginOffset.x, y: noteLocal.y + beginOffset.y,
        )
        let end: CGPoint
        if pair.sameNote {
            // A pre-bend anchored on its principal: mirroring the anchor
            // would put the end LEFT of the start. Collapse to a tick at
            // the begin anchor instead.
            end = start
        } else {
            let endOffset = GuitarBendGeometry.angularAnchorOffset(
                sp: sp, up: pair.up, start: false,
            )
            end = CGPoint(
                x: pair.toOrigin.x - system.origin.x + endOffset.x,
                y: pair.toOrigin.y - system.origin.y + endOffset.y,
            )
            // Degenerate/very tight spacing after the anchor offsets —
            // skip rather than draw an inverted bend (same guard
            // `attachGlissandi` applies after its insets).
            guard end.x > start.x else { return nil }
        }

        return .guitarBend(
            fromOrigin: start,
            vertex: GuitarBendGeometry.vertex(
                from: start, to: end, sp: sp, up: pair.up,
            ),
            toOrigin: end,
            slight: false,
        )
    }
}
