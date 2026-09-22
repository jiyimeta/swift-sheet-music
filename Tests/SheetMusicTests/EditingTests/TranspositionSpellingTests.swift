@testable import SheetMusicCore
import Testing

/// How a transposed note is SPELLED — the half of `TranspositionPlanner` the pitch arithmetic does not settle.
///
/// Two rules, both about keeping what the reader already knows about a note:
///
/// - **A whole number of octaves keeps the spelling.** An E♭ lifted an octave is an E♭, whichever path lifted it.
/// - **`respellInKey` keeps a note's place relative to the scale.** The tpc moves by as many fifths as the key does,
///   so a chromatic note is still the same chromatic degree afterwards — not merely the plainest name for its pitch.
@Suite("Transposition spelling")
struct TranspositionSpellingTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    private static func chord(_ pitch: Int, _ tpc: Int) -> VoiceElement {
        .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: tpc)]))
    }

    private static func note(_ score: Score, _ element: Int) -> Note? {
        guard case let .chord(chord)? = score[slot(element)] else { return nil }
        return chord.notes.first
    }

    /// One 4/4 bar: `[ts, ks, first, second, r, r]`, the key signature written with `SetKeySignature` so it sits
    /// where a real score carries it.
    private static func bar(key: Int, _ first: VoiceElement, _ second: VoiceElement) throws -> Score {
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            first, second, .rest(duration: .quarter), .rest(duration: .quarter),
        ])
        let staff = Staff(measures: [Measure(voices: [voice])])
        var score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])])
        _ = try SetKeySignature(measureIndex: 0, concertKey: key).apply(to: &score)
        return score
    }

    /// B major with its lowered sixth: G♮4, then the tonic B4. Elements 2 and 3 once the signature is in.
    private static func bMajorWithFlatSixth() throws -> Score {
        try bar(key: 5, chord(67, 15), chord(71, 19))
    }

    // MARK: - Octaves

    @Test("an octave keeps a note's spelling, where twelve semitone steps would not")
    func octaveKeepsSpelling() throws {
        let eFlat = Note(pitch: 63, tpc: 11, accidental: .flat)
        let up = try #require(eFlat.shifted(bySemitones: 12, in: 0))
        #expect(up.pitch == 75)
        #expect(up.tpc == 11) // E♭, not the D♯ the step rule reaches
        #expect(up.accidental == .flat)
        let down = try #require(eFlat.shifted(bySemitones: -24, in: 0))
        #expect(down.pitch == 39)
        #expect(down.tpc == 11)
        #expect(Note(pitch: 120, tpc: 14).shifted(bySemitones: 12, in: 0) == nil) // still bounded by MIDI
    }

    @Test("a range moved an octave keeps every spelling — MuseScore's Ctrl+↑")
    func rangeOctaveKeepsSpelling() throws {
        var score = try Self.bar(key: 0, Self.chord(63, 11), Self.chord(66, 20)) // E♭4, F♯4 in C major
        let range = VoiceElementRange(start: Self.slot(2), end: Self.slot(3))
        _ = try TransposeRange(over: range, semitones: 12, respellInKey: false).apply(to: &score)
        #expect(Self.note(score, 2)?.pitch == 75)
        #expect(Self.note(score, 2)?.tpc == 11)
        #expect(Self.note(score, 3)?.pitch == 78)
        #expect(Self.note(score, 3)?.tpc == 20)
    }

    @Test("an octave leaves even a seven-accidental key alone")
    func octaveLeavesTheKey() {
        #expect(TranspositionPlanner.key(7, transposedBy: 12) == 7) // C♯ major, not D♭ major
        #expect(TranspositionPlanner.key(-7, transposedBy: -24) == -7)
    }

    // MARK: - Scale degree

    @Test("B major's ♭6 moved down three semitones is A♭ major's ♭6 — F♭, not E♮")
    func chromaticDegreeSurvives() throws {
        var score = try Self.bMajorWithFlatSixth()
        _ = try TransposeScore(semitones: -3, transposeKeySignatures: true).apply(to: &score)
        #expect(KeySignatureStaves.explicitKey(in: score, staff: Self.staff0, measureIndex: 0)?.concertKey == -4)
        #expect(Self.note(score, 2)?.pitch == 64)
        #expect(Self.note(score, 2)?.tpc == 6) // F♭
        #expect(Self.note(score, 2)?.accidental == .flat)
        #expect(Self.note(score, 3)?.pitch == 68)
        #expect(Self.note(score, 3)?.tpc == 10) // A♭, the new tonic
        #expect(Self.note(score, 3)?.accidental == nil)
    }

    @Test("with the key signatures left behind, notes are spelled for the key the music would have moved to")
    func keysLeftBehind() throws {
        var score = try Self.bMajorWithFlatSixth()
        _ = try TransposeScore(semitones: -3, transposeKeySignatures: false).apply(to: &score)
        #expect(KeySignatureStaves.explicitKey(in: score, staff: Self.staff0, measureIndex: 0)?.concertKey == 5)
        #expect(Self.note(score, 2)?.tpc == 6) // F♭ …
        #expect(Self.note(score, 2)?.accidental == .flat) // … drawn against B major's F♯
        #expect(Self.note(score, 3)?.tpc == 10) // A♭
        #expect(Self.note(score, 3)?.accidental == .flat) // against B major's A♯
    }

    @Test("a range respelled in its key keeps the scale degree too")
    func rangeKeepsTheDegree() throws {
        var score = try Self.bMajorWithFlatSixth()
        let range = VoiceElementRange(start: Self.slot(2), end: Self.slot(3))
        _ = try TransposeRange(over: range, semitones: -3, respellInKey: true).apply(to: &score)
        #expect(Self.note(score, 2)?.tpc == 6)
        #expect(Self.note(score, 3)?.tpc == 10)
    }

    @Test("a double accidental the scale asks for is written, and one past it is read back to its enharmonic")
    func doubleAccidentalBound() throws {
        // E major's raised fifth, B♯, moved up two semitones into F♯ major is its raised fifth there: C𝄪.
        var sharpened = try Self.bar(key: 4, Self.chord(72, 26), Self.chord(64, 18))
        _ = try TransposeScore(semitones: 2, transposeKeySignatures: true).apply(to: &sharpened)
        #expect(Self.note(sharpened, 2)?.pitch == 74)
        #expect(Self.note(sharpened, 2)?.tpc == 28) // C𝄪
        #expect(Self.note(sharpened, 2)?.accidental == .doubleSharp)
        // C♭ major up a semitone is C major, seven fifths sharpwards: a D𝄪 there would become a D-triple-sharp,
        // which no accidental writes, so it is read back twelve fifths to the E♯ it sounds as.
        var doubled = try Self.bar(key: -7, Self.chord(64, 30), Self.chord(59, 7)) // D𝄪4, C♭4
        _ = try TransposeScore(semitones: 1, transposeKeySignatures: true).apply(to: &doubled)
        #expect(Self.note(doubled, 2)?.pitch == 65)
        #expect(Self.note(doubled, 2)?.tpc == 25) // E♯
        #expect(Self.note(doubled, 3)?.tpc == 14) // C♭ → C, the tonic moved with its key
    }
}
