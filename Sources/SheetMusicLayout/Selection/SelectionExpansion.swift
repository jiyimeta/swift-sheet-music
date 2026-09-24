import SheetMusicCore

/// Turns a `ScoreSelection` into the set of item IDs a renderer should light up. Platform-neutral half of what used
/// to be `SelectionRenderState` — Android tints the same IDs through a draw-program re-encode, and a second
/// implementation of "which IDs does a tuplet selection cover" is exactly the divergence the parity rule forbids.
public enum SelectionExpansion {
    /// For non-tuplet IDs returns `[id]`; for a tuplet returns the tuplet ID itself plus every member chord/rest the
    /// bracket spans. Keeping the tuplet ID in the result lets a renderer tint the bracket / number, while the member
    /// IDs drive notehead / rest tinting through the same pipeline.
    ///
    /// A `.graceNote` expands to itself alone, and a `.note` never to the graces beside it: renderers key a grace
    /// head by `LayoutChordNote.selectionItem`, so the two selections light disjoint heads. A tuplet's member notes
    /// are its chords' own notes, so a selected tuplet does not tint its members' graces either. A RANGE is the
    /// exception — see `selectedIDs(for:in:)`.
    public static func expand(
        _ id: ScoreItemID, in score: Score,
    ) -> Set<ScoreItemID> {
        guard case let .tuplet(tid) = id,
              let staffForTuplet = score[tid.staff]
        else { return [id] }
        let measures = staffForTuplet.measures
        guard measures.indices.contains(tid.measureIndex)
        else { return [id] }
        let voices = measures[tid.measureIndex].voices
        guard voices.indices.contains(tid.voiceIndex)
        else { return [id] }
        let voice = voices[tid.voiceIndex]
        guard let tuplet = voice.tupletSpans.first(where: { $0.startIndex == tid.startElementIndex })
        else { return [id] }
        let elements = voice.elements
        var out: Set<ScoreItemID> = [id]
        for j in tuplet.startIndex ... tuplet.endIndex {
            guard elements.indices.contains(j),
                  case let .chord(c) = elements[j]
            else { continue }
            if c.notes.isEmpty {
                out.insert(.rest(RestID(
                    staff: tid.staff,
                    measureIndex: tid.measureIndex,
                    voiceIndex: tid.voiceIndex,
                    elementIndex: j,
                )))
            } else {
                for ni in c.notes.indices {
                    out.insert(.note(NoteID(
                        staff: tid.staff,
                        measureIndex: tid.measureIndex,
                        voiceIndex: tid.voiceIndex,
                        elementIndex: j,
                        noteIndexInChord: ni,
                    )))
                }
            }
        }
        return out
    }

    /// Every ID `selection` covers, expanded. `.range` resolves through `score.items(inRangeFrom:to:)`, plus every
    /// grace note of every chord in it.
    ///
    /// **A range lights its graces.** A range edit carries them — a transposition moves a chord's grace notes with
    /// it (`TransposeRange`) — so a range that tinted every head but theirs looked as though it left them out
    /// (folino QA, 2026-09-24). Added here rather than in `items(inRangeFrom:to:)`, which is also the range the
    /// editing commands address and must keep naming notes and rests only.
    public static func selectedIDs(
        for selection: ScoreSelection, in score: Score,
    ) -> Set<ScoreItemID> {
        switch selection {
        case .none:
            return []
        case let .single(id):
            // Tuplet selection expands to the set of member IDs
            // (every note/rest the bracket spans) so the existing
            // per-element coloring path lights them up, in addition
            // to the bracket/number itself — `expand` keeps the
            // tuplet's own ID in the result for exactly that.
            return expand(id, in: score)
        case let .range(anchor, target):
            let items = Set(score.items(inRangeFrom: anchor, to: target))
            return items.union(graceNotes(ofChordsIn: items, in: score))
        case let .multi(ids):
            return ids.reduce(into: Set<ScoreItemID>()) {
                $0.formUnion(expand($1, in: score))
            }
        }
    }

    /// A `.graceNote` for every grace note, both sides, of each chord one of `items`' notes belongs to.
    static func graceNotes(ofChordsIn items: Set<ScoreItemID>, in score: Score) -> Set<ScoreItemID> {
        var chords = Set<VoiceElementID>()
        for case let .note(note) in items {
            chords.insert(VoiceElementID(note))
        }
        var out = Set<ScoreItemID>()
        for parent in chords {
            guard case let .chord(chord)? = score[parent] else { continue }
            for side in [GraceNoteID.Side.before, .after] {
                for (graceIndex, grace) in chord.graceNotes(on: side).enumerated() {
                    for noteIndex in grace.notes.indices {
                        out.insert(.graceNote(GraceNoteID(
                            parent: parent, side: side, graceIndex: graceIndex, noteIndexInGraceChord: noteIndex,
                        )))
                    }
                }
            }
        }
        return out
    }
}
