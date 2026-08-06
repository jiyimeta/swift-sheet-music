import SheetMusicCore

/// Turns a `ScoreSelection` into the set of item IDs a renderer should light up. Platform-neutral half of what used
/// to be `SelectionRenderState` — Android tints the same IDs through a draw-program re-encode, and a second
/// implementation of "which IDs does a tuplet selection cover" is exactly the divergence the parity rule forbids.
public enum SelectionExpansion {
    /// For non-tuplet IDs returns `[id]`; for a tuplet returns the tuplet ID itself plus every member chord/rest the
    /// bracket spans. Keeping the tuplet ID in the result lets a renderer tint the bracket / number, while the member
    /// IDs drive notehead / rest tinting through the same pipeline.
    public static func expand(
        _ id: ScoreItemID, in score: Score,
    ) -> Set<ScoreItemID> {
        guard case let .tuplet(tid) = id,
              let tuplet = score[tid],
              let staffForTuplet = score[tid.staff]
        else { return [id] }
        let measures = staffForTuplet.measures
        guard measures.indices.contains(tid.measureIndex)
        else { return [id] }
        let voices = measures[tid.measureIndex].voices
        guard voices.indices.contains(tid.voiceIndex)
        else { return [id] }
        let elements = voices[tid.voiceIndex].elements
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

    /// Every ID `selection` covers, expanded. `.range` resolves through `score.items(inRangeFrom:to:)`.
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
            return Set(score.items(inRangeFrom: anchor, to: target))
        case let .multi(ids):
            return ids.reduce(into: Set<ScoreItemID>()) {
                $0.formUnion(expand($1, in: score))
            }
        }
    }
}
