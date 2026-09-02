import SheetMusicFoundation

/// The system lane's slot arithmetic that `SetTempo` and `SetStaffText` share with `RehearsalMarkLane`: where a
/// chord sits in its bar, which lane element is "the one at that beat", and where a new one goes.
///
/// A lane mark is addressed by the chord or rest it sits on (spec 2026-09-02 §2.3): the intent carries that
/// element's `VoiceElementID` and this derives the `MeasurePosition` from `Score.onset(of:)`, the walker
/// `Score.voiceElements(in:)` ranks onsets with. A lane element MSCX placed at a tick no chord starts —
/// `<location>`-shifted — is unreachable this way, the limit §2.3 accepts for v1.
enum SystemLaneSlot {
    /// The lane position of the chord or rest at `anchor`: its onset as a fraction of a whole note. `nil` for a
    /// non-timed element (a clef has no tick of its own) or an anchor that does not resolve.
    static func position(of anchor: VoiceElementID, in score: Score) -> MeasurePosition? {
        guard case .chord? = score[anchor], let onset = score.onset(of: anchor) else { return nil }
        // `Fraction.init` reduces, so tick 960 at division 480 is 1/2 — equal to the 1/4 + 1/4 cursor the decoder
        // records for a lifted element there, and to `.start` at tick 0.
        return MeasurePosition(numerator: onset.tick, denominator: 4 * score.division)
    }

    /// Index of the first element of `measure` at `position` that `matches`, or `nil`.
    static func firstIndex(
        in measure: SystemMeasure, at position: MeasurePosition,
        where matches: (PositionedSystemElement) -> Bool,
    ) -> Int? {
        measure.elements.firstIndex { $0.position == position && matches($0) }
    }

    /// Where a new element at `position` goes: before the first element positioned later, since
    /// `SystemMeasure.elements` is document order — the rule `RehearsalMarkLane.write` applies at `.start`.
    static func insertionIndex(in measure: SystemMeasure, for position: MeasurePosition) -> Int {
        measure.elements.firstIndex { $0.position > position } ?? measure.elements.count
    }
}
