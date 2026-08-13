import SheetMusicCore
import SheetMusicFoundation

extension MidiRenderer {
    /// Propagate each tie chain's head pitch onto its continuation notes
    /// so playback holds the held note's sounding pitch — matching how
    /// MuseScore renders a tie.
    ///
    /// MuseScore plays a tie by sounding the FIRST note of the chain for
    /// the whole tied span; the tied-into notes are never re-attacked
    /// (`Note::tieBack()` is skipped in `CompatMidiRender`, and
    /// `Note::playTicksFraction()` reports the combined duration on the
    /// head). Our per-note emit (`emitNoteEventsForGrace`) splits that into "head
    /// emits the note-on, tail emits the note-off", which only balances
    /// when the two endpoints share a pitch.
    ///
    /// That assumption breaks for a tie whose endpoints carry different
    /// *sounding* pitches. MuseScore produces this shape naturally when a
    /// key signature changes mid-tie: the held note keeps its staff line
    /// but the key change re-spells it, so e.g. C♯ (pitch 73) ties into an
    /// invisible C-double-sharp (pitch 74). Left unresolved, the head's
    /// note-on is never released (a stuck note) and the tail emits a
    /// note-off for a pitch that was never struck.
    ///
    /// Rewriting each continuation note's pitch to the chain head makes
    /// the tail's note-off land on the held pitch. Same-pitch ties (the
    /// overwhelming majority) resolve to a no-op.
    static func resolvingTiedPitches(in score: Score) -> Score {
        var score = score
        for partIndex in score.parts.indices {
            for staffIndex in score.parts[partIndex].staves.indices {
                resolveTiedPitches(
                    in: &score.parts[partIndex].staves[staffIndex],
                )
            }
        }
        return score
    }

    private static func resolveTiedPitches(in staff: inout Staff) {
        let voiceCount = staff.measures.map(\.voices.count).max() ?? 0
        for voiceIndex in 0 ..< voiceCount {
            // Sounding head pitches flowing out of the previous note-chord,
            // awaiting a `tieBack` continuation. FIFO, in note order — ties
            // within a chord do not cross, so the i-th tie out pairs with
            // the i-th tie in.
            var incoming: [Int] = []
            for measureIndex in staff.measures.indices {
                guard voiceIndex < staff.measures[measureIndex].voices.count else {
                    // This voice is absent here; a tie cannot bridge the gap.
                    incoming = []
                    continue
                }
                let elementCount = staff.measures[measureIndex]
                    .voices[voiceIndex].elements.count
                for elementIndex in 0 ..< elementCount {
                    incoming = resolveTiedPitches(
                        elementIndex: elementIndex,
                        voiceIndex: voiceIndex,
                        measureIndex: measureIndex,
                        staff: &staff,
                        incoming: incoming,
                    )
                }
            }
        }
    }

    /// Resolve one voice element, returning the head pitches flowing out of
    /// it into the next note-chord.
    private static func resolveTiedPitches(
        elementIndex: Int,
        voiceIndex: Int,
        measureIndex: Int,
        staff: inout Staff,
        incoming: [Int],
    ) -> [Int] {
        let element = staff.measures[measureIndex]
            .voices[voiceIndex].elements[elementIndex]
        // Non-temporal elements (clef, key signature, dynamic, …) sit
        // between a tied chord and its continuation — a key change is the
        // very trigger here — and must NOT break the chain. Leave `incoming`
        // intact.
        guard case let .chord(chord) = element else { return incoming }
        // A rest severs any pending tie.
        if chord.notes.isEmpty { return [] }

        var queue = incoming
        var outgoing: [Int] = []
        var newChord = chord
        for noteIndex in newChord.notes.indices {
            var head = newChord.notes[noteIndex].pitch
            if newChord.notes[noteIndex].tieBack != nil, !queue.isEmpty {
                head = queue.removeFirst()
                if head != newChord.notes[noteIndex].pitch {
                    // `updateNote` no-ops on a pitch collision; the chain
                    // still logically holds `head`, so propagate it forward
                    // regardless of whether the rewrite landed.
                    newChord.notes.updateNote(at: noteIndex) { $0.pitch = head }
                }
            }
            if newChord.notes[noteIndex].tieForward != nil {
                outgoing.append(head)
            }
        }
        if newChord != chord {
            staff.measures[measureIndex]
                .voices[voiceIndex].elements[elementIndex] = .chord(newChord)
        }
        return outgoing
    }
}
