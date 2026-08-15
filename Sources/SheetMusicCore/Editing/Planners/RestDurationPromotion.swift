import Foundation

/// The write-side counterpart of `FullMeasureRestCollapse`: a rest that fills its bar from beat one is spelled
/// `.measure`, not as whatever literal length happens to add up to the same ticks.
///
/// `.measure` engraves as the meter-independent whole-bar rest; a literal duration that merely totals the same
/// ticks does not, and stops being correct the moment the meter changes. `SetRestDuration` and `CrossBarInputPlanner`
/// both write whatever duration they're handed without judging whether it fills the bar — this is where that
/// judgment happens, once, so a caller that resolves an armed length into a plain retime doesn't have to re-derive
/// it. `CrossBarInputPlanner` needs no equivalent call: a chain segment that fills its measure end to end already
/// promotes itself (see its `durations(forTicks:rtickStart:inMeasure:room:content:)`).
public enum RestDurationPromotion {
    /// `duration` promoted to `.measure` when a rest of that length written at `location` would fill its bar from
    /// beat one, otherwise `duration` unchanged.
    ///
    /// "From beat one" only: a rest that happens to total a bar's worth of ticks but starts partway through the bar
    /// — after an earlier chord or rest in the same voice — can't be read as "this whole bar is silent", whatever
    /// its length says. A `location` that doesn't resolve is left to whichever command actually judges it; this
    /// returns `duration` unchanged rather than guessing.
    public static func promoted(
        _ duration: NoteDuration, at location: VoiceElementID, in score: Score,
    ) -> NoteDuration {
        guard let staff = score[location.staff], staff.measures.indices.contains(location.measureIndex) else {
            return duration
        }
        let measureDurations = score.effectiveMeasureDurations(
            partIndex: location.staff.partIndex, staffIndex: location.staff.staffIndexInPart,
        )
        guard measureDurations.indices.contains(location.measureIndex) else { return duration }
        let measureDuration = measureDurations[location.measureIndex]
        let division = score.division
        guard duration.resolved(in: measureDuration).ticks(division: division)
            == measureDuration.ticks(division: division)
        else { return duration }
        let voices = staff.measures[location.measureIndex].voices
        guard voices.indices.contains(location.voiceIndex) else { return duration }
        let preceding = voices[location.voiceIndex].elements.prefix(location.elementIndex)
        guard !preceding.contains(where: { if case .chord = $0 { true } else { false } }) else { return duration }
        return .measure
    }
}
