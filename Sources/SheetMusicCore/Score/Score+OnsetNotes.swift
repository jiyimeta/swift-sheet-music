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
    /// Onsets are measured the way ``resolveTickInMeasure(for:)`` measures them, so the answer agrees with the tick
    /// a cursor on `item` reports.
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
            var tick = 0
            for (elementIndex, element) in voice.elements.enumerated() {
                guard tick <= target else { break }
                guard case let .chord(chord) = element else { continue }
                if tick == target {
                    for noteIndex in chord.notes.indices {
                        noteIDs.append(NoteID(
                            staff: item.staff, measureIndex: item.measureIndex, voiceIndex: voiceIndex,
                            elementIndex: elementIndex, noteIndexInChord: noteIndex,
                        ))
                    }
                }
                tick += chord.duration.resolved(in: measureDuration).ticks(division: division)
            }
        }
        return noteIDs
    }
}
