@testable import SheetMusicCore
import Testing

/// Pins the other half of the tick-walker convention `TupletOnsetTests` states: a `.locationShift` moves the
/// running tick, exactly as the MSCX encoder's write cursor (`advanceWriteCursor`), `Score+FermataHolds` and the
/// layout spanner walkers already do. `Score.onset(of:)` is what `SystemLaneSlot.position` derives a lane mark's
/// `MeasurePosition` from, so a walker that ignored the jog anchored `SetTempo` / `SetStaffText` at the wrong beat.
@Suite("Location shifts move the onset cursor")
struct LocationShiftOnsetTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    /// `[ts, <location> +1/4, C4 q, r q, r q]` — the bar a MuseScore file spells when its voice starts a beat in.
    private static func shiftedScore() -> Score {
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .locationShift(delta: Fraction(numerator: 1, denominator: 4)),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .rest(duration: .quarter),
            .rest(duration: .quarter),
        ])
        let staff = Staff(measures: [Measure(voices: [voice])])
        let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])
        return Score(division: 480, parts: [part])
    }

    @Test("the chord after a +1/4 jog starts on beat 2, and its end follows")
    func onsetHonorsTheJog() {
        let score = Self.shiftedScore()
        #expect(score.onset(of: Self.slot(2)) == ScoreTickPosition(measure: 0, tick: 480))
        #expect(score.end(of: Self.slot(2)) == ScoreTickPosition(measure: 0, tick: 960))
        #expect(score.onset(of: Self.slot(3)) == ScoreTickPosition(measure: 0, tick: 960))
    }

    @Test("the range walker still finds the shifted chord — every walker uses the same cursor")
    func rangeWalkerAgrees() {
        let score = Self.shiftedScore()
        let range = VoiceElementRange(start: Self.slot(2), end: Self.slot(2))
        #expect(score.voiceElements(in: range) == [Self.slot(2)])
        let wide = VoiceElementRange(start: Self.slot(2), end: Self.slot(4))
        #expect(score.voiceElements(in: wide) == [Self.slot(2), Self.slot(3), Self.slot(4)])
    }

    @Test("a tempo anchored on the shifted chord lands on beat 2, not the downbeat")
    func laneMarkLandsOnTheShiftedBeat() throws {
        var score = Self.shiftedScore()
        _ = try SetTempo(anchor: Self.slot(2), marking: SetTempo.Marking(beatsPerSecond: 2.5)).apply(to: &score)
        #expect(score.systemMeasures[0].elements.first?.position == MeasurePosition(numerator: 1, denominator: 4))
    }

    @Test("staff text anchored on the shifted chord lands on the same beat")
    func staffTextLandsOnTheShiftedBeat() throws {
        var score = Self.shiftedScore()
        _ = try SetStaffText(anchor: Self.slot(2), text: "pizz.", isSystemText: false).apply(to: &score)
        #expect(score.systemMeasures[0].elements.first?.position == MeasurePosition(numerator: 1, denominator: 4))
    }
}
