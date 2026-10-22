import SheetMusicFoundation

/// Voice-order walking for caret auto-advance: the caret should step forward after a pitch-key input, but not
/// after a drag.
public enum ElementNavigator {
    /// The next chord/rest slot after `location` in the same voice, skipping non-timed elements
    /// (clef / key sig / time sig / barline / …), continuing into the next measure's same voice.
    /// `nil` at the end of the staff.
    public static func nextTimedElement(after location: VoiceElementID, in score: Score) -> VoiceElementID? {
        guard let staff = score[location.staff] else { return nil }
        var measureIndex = location.measureIndex
        var elementIndex = location.elementIndex + 1
        while staff.measures.indices.contains(measureIndex) {
            let voices = staff.measures[measureIndex].voices
            guard voices.indices.contains(location.voiceIndex) else { return nil }
            let elements = voices[location.voiceIndex].elements
            while elements.indices.contains(elementIndex) {
                if isStop(elements[elementIndex], in: staff.measures[measureIndex], voiceIndex: location.voiceIndex) {
                    return VoiceElementID(
                        staff: location.staff,
                        measureIndex: measureIndex,
                        voiceIndex: location.voiceIndex,
                        elementIndex: elementIndex,
                    )
                }
                elementIndex += 1
            }
            measureIndex += 1
            elementIndex = 0
        }
        return nil
    }

    /// The mirror of `nextTimedElement(after:)`, walking backwards through the same voice and into the previous
    /// measure. Used to step the selection backward along the voice without re-aiming a tap. `nil` at the start of
    /// the staff.
    public static func previousTimedElement(before location: VoiceElementID, in score: Score) -> VoiceElementID? {
        guard let staff = score[location.staff] else { return nil }
        var measureIndex = location.measureIndex
        var elementIndex = location.elementIndex - 1
        while measureIndex >= 0, staff.measures.indices.contains(measureIndex) {
            let voices = staff.measures[measureIndex].voices
            guard voices.indices.contains(location.voiceIndex) else { return nil }
            let elements = voices[location.voiceIndex].elements
            while elementIndex >= 0, elements.indices.contains(elementIndex) {
                if isStop(elements[elementIndex], in: staff.measures[measureIndex], voiceIndex: location.voiceIndex) {
                    return VoiceElementID(
                        staff: location.staff,
                        measureIndex: measureIndex,
                        voiceIndex: location.voiceIndex,
                        elementIndex: elementIndex,
                    )
                }
                elementIndex -= 1
            }
            measureIndex -= 1
            // Resume from the last element of the measure we just stepped back into.
            guard measureIndex >= 0, staff.measures.indices.contains(measureIndex),
                  staff.measures[measureIndex].voices.indices.contains(location.voiceIndex)
            else { return nil }
            elementIndex = staff.measures[measureIndex].voices[location.voiceIndex].elements.count - 1
        }
        return nil
    }

    /// A chord or rest slot, or a measure repeat — the only elements a voice-order walk should stop on. Deliberately
    /// NOT `VoiceElement.tickCount(division:) != nil`: `NoteDuration.ticks(division:)` traps on `.measure` until
    /// `resolved(in:)` runs against the containing measure's duration, and an unresolved measure-filling rest
    /// (`.chord(Chord(duration: .measure, notes: []))`) is exactly the kind of slot a voice-order walk must stop on.
    /// Pattern-matching (`VoiceElement.isRangeSlot`) is the crash-free equivalent.
    private static func isTimedSlot(_ element: VoiceElement) -> Bool {
        element.isRangeSlot
    }

    /// `isTimedSlot`, less a rest a measure-repeat group's bar holds under the group's sign: it is never shown, so
    /// the walk passes it as MuseScore's does (`skipMeasureRepeatRests`, "these rests are not shown"). Any bar of
    /// the group — MuseScore anchors a 2- or 4-bar group's sign in a middle bar, so bar 1 holds such a rest too.
    private static func isStop(_ element: VoiceElement, in measure: Measure, voiceIndex: Int) -> Bool {
        guard isTimedSlot(element) else { return false }
        return !(voiceIndex == 0 && element.isRest && measure.measureRepeatCount != nil)
    }
}
