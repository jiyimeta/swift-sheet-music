@testable import SheetMusicCore
import Testing

@Suite("InputNote")
struct InputNoteTests {
    private static let restAt1 = RestID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0,
        voiceIndex: 0, elementIndex: 1,
    )

    @Test("apply replaces the rest with a single-note chord at the same duration")
    func applyReplacesRest() throws {
        var score = EditingFixtures.fourQuarterRests()
        let cmd = InputNote(at: Self.restAt1, pitch: 60, tpc: 14) // C4
        _ = try cmd.apply(to: &score)
        let veID = VoiceElementID(Self.restAt1)
        guard case let .chord(chord) = score[veID] else {
            Issue.record("expected chord")
            return
        }
        #expect(chord.duration == .quarter)
        #expect(chord.notes.count == 1)
        #expect(chord.notes[0].pitch == 60)
        #expect(chord.notes[0].tpc == 14)
    }

    @Test("inverse restores the original rest")
    func inverseRestoresRest() throws {
        var score = EditingFixtures.fourQuarterRests()
        let original = score
        let cmd = InputNote(at: Self.restAt1, pitch: 60, tpc: 14)
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    private static let restAt1InEmptyBar = RestID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0,
        voiceIndex: 0, elementIndex: 1,
    )

    /// `.measure` is a REST-only spelling — it means "however long this bar
    /// is", which only a rest may say. A chord has to name a real duration:
    /// MuseScore's `Chord::write` has no `measure` durationType, and this
    /// package's own `MSCXEncoder` traps rather than emit one. So writing a
    /// note onto an empty bar has to resolve the bar's length, not inherit
    /// the rest's placeholder.
    ///
    /// Getting this wrong is invisible until the score is SAVED: layout
    /// resolves `.measure` against the bar and draws the note correctly, so
    /// the crash lands at export, long after the edit that caused it.
    @Test("writing onto a full-measure rest resolves the bar's length, never .measure")
    func applyOnFullMeasureRest() throws {
        var score = EditingFixtures.fullMeasureRest()
        let cmd = InputNote(at: Self.restAt1InEmptyBar, pitch: 60, tpc: 14)
        _ = try cmd.apply(to: &score)
        guard case let .chord(chord) = score[VoiceElementID(Self.restAt1InEmptyBar)] else {
            Issue.record("expected chord")
            return
        }
        #expect(chord.duration != .measure)
        #expect(chord.duration.asFraction == Fraction(numerator: 4, denominator: 4))
    }

    /// The resolved length is the BAR's, not a hardcoded whole note: in 3/4
    /// the note that fills the bar is a dotted half.
    @Test("the resolved length follows the bar's own meter")
    func applyOnFullMeasureRestInThreeFour() throws {
        var score = EditingFixtures.fullMeasureRest(numerator: 3, denominator: 4)
        let cmd = InputNote(at: Self.restAt1InEmptyBar, pitch: 60, tpc: 14)
        _ = try cmd.apply(to: &score)
        guard case let .chord(chord) = score[VoiceElementID(Self.restAt1InEmptyBar)] else {
            Issue.record("expected chord")
            return
        }
        #expect(chord.duration != .measure)
        #expect(chord.duration.asFraction == Fraction(numerator: 3, denominator: 4))
    }

    /// The inverse still has to put the ORIGINAL `.measure` rest back — the
    /// resolution happens on the way in only, so undo restores the empty bar
    /// exactly as it was spelled.
    @Test("inverse restores the full-measure rest as .measure")
    func inverseRestoresFullMeasureRest() throws {
        var score = EditingFixtures.fullMeasureRest()
        let original = score
        let cmd = InputNote(at: Self.restAt1InEmptyBar, pitch: 60, tpc: 14)
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == original)
    }

    @Test("apply throws when target is not a rest")
    func applyOnChord() throws {
        var score = EditingFixtures.chordAtIndex1()
        let cmd = InputNote(at: Self.restAt1, pitch: 62, tpc: 16)
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }
}
