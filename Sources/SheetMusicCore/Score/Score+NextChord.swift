import SheetMusicFoundation

extension Score {
    /// Walk forward in the same staff + voice from `voiceElementID`
    /// and return the next chord's location. Crosses measure
    /// boundaries automatically; non-chord elements (rests, clefs,
    /// key sigs, time sigs, barlines, etc.) are skipped.
    ///
    /// Returns `nil` when the end of the staff is reached without
    /// finding another chord. Used by the lyric editor's Space-key
    /// "advance to next syllable" flow and any future
    /// chord-by-chord navigation.
    public func nextChord(after voiceElementID: VoiceElementID) -> VoiceElementID? {
        let staffAddr = voiceElementID.staff
        let voiceIndex = voiceElementID.voiceIndex
        guard let staffValue = self[staffAddr] else {
            return nil
        }
        let measures = staffValue.measures

        // First search the rest of the current measure.
        if voiceElementID.measureIndex < measures.count {
            let voices = measures[voiceElementID.measureIndex].voices
            if voiceIndex < voices.count {
                let elements = voices[voiceIndex].elements
                let start = voiceElementID.elementIndex + 1
                if start < elements.count {
                    for idx in start ..< elements.count {
                        if case let .chord(c) = elements[idx],
                           !c.notes.isEmpty
                        {
                            return VoiceElementID(
                                staff: staffAddr,
                                measureIndex: voiceElementID.measureIndex,
                                voiceIndex: voiceIndex,
                                elementIndex: idx,
                            )
                        }
                    }
                }
            }
        }

        // Then walk subsequent measures.
        let firstNext = voiceElementID.measureIndex + 1
        guard firstNext < measures.count else { return nil }
        for mIdx in firstNext ..< measures.count {
            let voices = measures[mIdx].voices
            guard voiceIndex < voices.count else { continue }
            let elements = voices[voiceIndex].elements
            for (idx, el) in elements.enumerated() {
                if case let .chord(c) = el, !c.notes.isEmpty {
                    return VoiceElementID(
                        staff: staffAddr,
                        measureIndex: mIdx,
                        voiceIndex: voiceIndex,
                        elementIndex: idx,
                    )
                }
            }
        }
        return nil
    }

    /// Walk backward in the same staff + voice from `voiceElementID` and return the previous sounding chord.
    /// Crosses measure boundaries automatically and skips rests and every non-chord element.
    public func previousChord(before voiceElementID: VoiceElementID) -> VoiceElementID? {
        let staffAddr = voiceElementID.staff
        let voiceIndex = voiceElementID.voiceIndex
        guard let staffValue = self[staffAddr],
              staffValue.measures.indices.contains(voiceElementID.measureIndex)
        else { return nil }
        let measures = staffValue.measures

        let currentVoices = measures[voiceElementID.measureIndex].voices
        if currentVoices.indices.contains(voiceIndex) {
            let elements = currentVoices[voiceIndex].elements
            let end = min(max(voiceElementID.elementIndex, 0), elements.count)
            for index in elements[..<end].indices.reversed() {
                if case let .chord(chord) = elements[index], !chord.notes.isEmpty {
                    return VoiceElementID(
                        staff: staffAddr,
                        measureIndex: voiceElementID.measureIndex,
                        voiceIndex: voiceIndex,
                        elementIndex: index,
                    )
                }
            }
        }

        guard voiceElementID.measureIndex > 0 else { return nil }
        for measureIndex in stride(from: voiceElementID.measureIndex - 1, through: 0, by: -1) {
            let voices = measures[measureIndex].voices
            guard voices.indices.contains(voiceIndex) else { continue }
            let elements = voices[voiceIndex].elements
            for index in elements.indices.reversed() {
                if case let .chord(chord) = elements[index], !chord.notes.isEmpty {
                    return VoiceElementID(
                        staff: staffAddr,
                        measureIndex: measureIndex,
                        voiceIndex: voiceIndex,
                        elementIndex: index,
                    )
                }
            }
        }
        return nil
    }
}
