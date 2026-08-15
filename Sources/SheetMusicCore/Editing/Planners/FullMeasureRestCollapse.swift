import Foundation

/// Turns "the last note in this voice-measure just got deleted" into a single full-measure rest.
///
/// `DeleteVoiceElement` swaps the element for a rest of the SAME duration, which keeps the measure's total length
/// right but leaves the leftovers of whatever rhythm used to be there — delete the quarter note in front of three
/// quarter rests and you get four quarter rests, when what the measure now means is simply "silent bar". MuseScore
/// writes that as one measure-filling rest (`NoteDuration.measure`, engraved as a whole rest whatever the meter),
/// and so does this.
///
/// The collapse is planned BEFORE the delete rather than applied after it, so the whole thing stays one command and
/// therefore one undo step: `ReplaceVoiceElements` subsumes the delete instead of following it.
public enum FullMeasureRestCollapse {
    public struct Plan {
        public let command: ReplaceVoiceElements
        /// Index of the measure rest inside the replacement element list, so the caller can land the selection on it
        /// (`ReplaceVoiceElements` reports element 0 as its affected location, which is usually a clef or the time
        /// signature rather than anything selectable).
        public let restElementIndex: Int
    }

    /// A plan for deleting `location`, or `nil` when the delete doesn't empty the measure — in which case the caller
    /// falls back to a plain `DeleteVoiceElement`.
    ///
    /// Non-timed elements (clef / key sig / time sig / barline / harmony / …) are carried over untouched and in
    /// order; only the timed run collapses. Tuplets go with it: their bracket spans element indices that no longer
    /// exist once the run is one slot long.
    public static func plan(deleting location: VoiceElementID, in score: Score) -> Plan? {
        guard let staff = score[location.staff],
              staff.measures.indices.contains(location.measureIndex)
        else { return nil }
        let voices = staff.measures[location.measureIndex].voices
        guard voices.indices.contains(location.voiceIndex) else { return nil }
        let voice = voices[location.voiceIndex]
        guard voice.elements.indices.contains(location.elementIndex) else { return nil }

        // Every other timed slot has to be a rest already — otherwise deleting this one leaves music behind and the
        // measure keeps its rhythm.
        for (index, element) in voice.elements.enumerated() where index != location.elementIndex {
            if case let .chord(chord) = element, !chord.notes.isEmpty { return nil }
        }

        var elements: [VoiceElement] = []
        var restElementIndex: Int?
        for element in voice.elements {
            guard case .chord = element else {
                elements.append(element)
                continue
            }
            if restElementIndex == nil {
                restElementIndex = elements.count
                elements.append(.rest(duration: .measure))
            }
        }
        guard let restElementIndex else { return nil }
        // Nothing to do when the measure already reads as one full-measure rest.
        guard elements != voice.elements || !voice.tuplets.isEmpty else { return nil }

        return Plan(
            command: ReplaceVoiceElements(
                staff: location.staff,
                measureIndex: location.measureIndex,
                voiceIndex: location.voiceIndex,
                elements: elements,
                tuplets: [],
            ),
            restElementIndex: restElementIndex,
        )
    }
}
