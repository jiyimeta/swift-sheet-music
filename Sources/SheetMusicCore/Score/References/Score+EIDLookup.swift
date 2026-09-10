import SheetMusicFoundation

/// Identity lookup for top-level `Voice.elements` in every voice, measure, staff, and part.
/// Grace chords nested in a chord, tuplets, system-lane elements in `Score.systemMeasures`,
/// parts, staves, and measure columns are outside this scope: `VoiceElementID` cannot address them.
///
/// A `VoiceElementID` names a position, and edits move and vacate positions. Removing an element
/// shifts every later element's index, so a positional selection must not be carried across a removal.
/// To follow an element across an edit, resolve `eid(at:)` before the edit and `position(of:)` after it.
/// Lookup by EID walks the score, linear in the number of voice elements; callers resolving many
/// identifiers should build their own map.
extension Score {
    /// The voice element with this identifier, or `nil` if it is invalid or absent.
    public subscript(eid eid: EID) -> VoiceElement? {
        guard let position = position(of: eid) else { return nil }
        return self[position]
    }

    /// The first match in part, staff, measure, voice, then element order, or `nil` for an invalid
    /// or absent identifier. Identifiers are expected to be unique: `ScoreEditor`'s debug gate checks
    /// that after every edit. If they repeat anyway, the first match in this order wins.
    public func position(of eid: EID) -> VoiceElementID? {
        guard eid.isValid else { return nil }
        for (partIndex, part) in parts.enumerated() {
            for (staffIndex, staff) in part.staves.enumerated() {
                for (measureIndex, measure) in staff.measures.enumerated() {
                    for (voiceIndex, voice) in measure.voices.enumerated() {
                        guard let elementIndex = voice.elements.index(of: eid) else { continue }
                        return VoiceElementID(
                            staff: StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex),
                            measureIndex: measureIndex, voiceIndex: voiceIndex, elementIndex: elementIndex,
                        )
                    }
                }
            }
        }
        return nil
    }

    /// The slot's durable identifier, or `nil` if the position is out of range or still unassigned.
    public func eid(at position: VoiceElementID) -> EID? {
        guard let staff = self[position.staff],
              staff.measures.indices.contains(position.measureIndex)
        else { return nil }
        let voices = staff.measures[position.measureIndex].voices
        guard voices.indices.contains(position.voiceIndex) else { return nil }
        let elements = voices[position.voiceIndex].elements
        guard elements.indices.contains(position.elementIndex) else { return nil }
        let eid = elements.eid(at: position.elementIndex)
        return eid.isValid ? eid : nil
    }
}
