import SheetMusicFoundation

/// Turns "the caller is about to clear every timed slot in this voice-measure" into a single full-measure rest.
///
/// Clearing a slot leaves a rest of the same length behind, which keeps the measure's tick total right but spells a
/// silent bar as the leftovers of whatever rhythm used to be there — four quarter rests where what the measure now
/// means is simply "silent bar". MuseScore writes that as one measure-filling rest (`NoteDuration.measure`,
/// engraved as a whole rest whatever the meter), and so does this.
///
/// **The collapse is gated on COVERAGE, not on what survives.** It applies only when the caller is clearing every
/// timed slot of the voice — a rest the user did not select is a rest the edit may not touch, so a bar holding a
/// half note and a half rest gives back two half rests when only the note is deleted, never a measure rest. (Before
/// 2026-09-13 the test was "is everything else already a rest?", which let one deleted note swallow rests nobody
/// had selected.)
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

    /// A plan for clearing the timed slots `covered` of `voice`, or `nil` when they are not all of them — in which
    /// case the caller falls back to whatever it does with a partial clear (`DeleteVoiceElement` for one slot, an
    /// aligned rest fill for a range). Also `nil` when the voice already reads as one measure rest.
    ///
    /// Non-timed elements (clef / key sig / time sig / barline / harmony / …) are carried over untouched and in
    /// order; only the timed run collapses. Tuplets go with it: their bracket spans element indices that no longer
    /// exist once the run is one slot long.
    public static func plan(clearing covered: Set<Int>, in ref: VoiceRef, of score: Score) -> Plan? {
        guard let voice = score[voice: ref] else { return nil }

        var elements: [VoiceSlot] = []
        var restElementIndex: Int?
        for (index, element) in voice.elements.enumerated() {
            guard case .chord = element else {
                elements.append(VoiceSlot(identity: .keep(voice.elements.eid(at: index)), element: element))
                continue
            }
            // A timed slot the caller is NOT clearing keeps the bar's rhythm, whether it holds notes or not.
            guard covered.contains(index) else { return nil }
            if restElementIndex == nil {
                restElementIndex = elements.count
                elements.append(VoiceSlot(
                    identity: element.isRest ? .keep(voice.elements.eid(at: index)) : .fresh,
                    element: .rest(duration: .measure),
                ))
            }
        }
        guard let restElementIndex else { return nil }
        // Nothing to do when the measure already reads as one full-measure rest.
        guard elements.map(\.element) != voice.elements.values || !voice.tuplets.isEmpty else { return nil }

        return Plan(
            command: ReplaceVoiceElements(
                staff: ref.staff,
                measureIndex: ref.measureIndex,
                voiceIndex: ref.voiceIndex,
                slots: elements,
                tuplets: [],
            ),
            restElementIndex: restElementIndex,
        )
    }
}
