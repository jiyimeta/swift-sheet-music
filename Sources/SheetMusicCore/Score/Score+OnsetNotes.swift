extension Score {
    /// Every note that begins at the same instant as `item` on `item`'s staff: each note of every chord, in every
    /// voice, whose onset is `item`'s own. What a tap on a beat should sound — a drum part written as hands in voice 1
    /// and feet in voice 2 sounds the kick with the cymbal, and a beat whose voice 1 is a rest still sounds voice 2.
    ///
    /// Ordered by voice, then chord order within a voice. Notes still ringing from an earlier onset are not included:
    /// they began somewhere else, and a tap asks what starts here. Grace notes are not included either — they sound
    /// before the beat, not on it.
    ///
    /// Works for a `.rest` as well as a `.note`, since a rest in one voice can sit on an onset another voice fills.
    /// Empty for an item that names no slot (a tuplet bracket, text, a clef) or for an address that does not resolve.
    ///
    /// Onsets are measured the way ``resolveTickInMeasure(for:)`` measures them — the voice's running tick, a
    /// `.locationShift` jog included — so the answer agrees with the tick a cursor on `item` reports, and a voice the
    /// file jogs to a later beat is heard on that beat.
    public func onsetNoteIDs(of item: ScoreItemID) -> [NoteID] {
        switch item {
        case .note, .rest: break
        default: return []
        }
        guard let target = resolveTickInMeasure(for: item),
              let staff = self[item.staff],
              staff.measures.indices.contains(item.measureIndex)
        else { return [] }
        let measureDuration = staff.measures.effectiveMeasureDurations()[item.measureIndex]
        var noteIDs: [NoteID] = []
        for (voiceIndex, voice) in staff.measures[item.measureIndex].voices.enumerated() {
            // The whole voice, not up to the target: a jog can move the cursor backwards.
            var tick = 0
            for (elementIndex, element) in voice.elements.enumerated() {
                if tick == target, case let .chord(chord) = element {
                    for noteIndex in chord.notes.indices {
                        noteIDs.append(NoteID(
                            staff: item.staff, measureIndex: item.measureIndex, voiceIndex: voiceIndex,
                            elementIndex: elementIndex, noteIndexInChord: noteIndex,
                        ))
                    }
                }
                tick += element.cursorAdvance(division: division, in: measureDuration)
            }
        }
        return noteIDs
    }
}
