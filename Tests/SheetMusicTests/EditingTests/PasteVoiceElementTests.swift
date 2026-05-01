@testable import SheetMusicCore
import Testing

@Suite("PasteVoiceElement")
struct PasteVoiceElementTests {
    private static let restID = VoiceElementID(
        staffIndex: 0, measureIndex: 0,
        voiceIndex: 0, elementIndex: 2)
    private static let chordID = VoiceElementID(
        staffIndex: 0, measureIndex: 0,
        voiceIndex: 0, elementIndex: 1)

    @Test("paste a same-duration chord onto a rest replaces it")
    func pasteChordOnMatchingRest() throws {
        var score = EditingFixtures.fourQuarterRests()
        let chord = Chord(
            duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        let cmd = PasteVoiceElement(
            at: Self.restID, element: .chord(chord))
        _ = try cmd.apply(to: &score)
        guard case .chord(let pasted) = score[Self.restID] else {
            Issue.record("not a chord"); return
        }
        #expect(pasted.notes.first?.pitch == 60)
    }

    @Test("paste a longer source consumes following elements")
    func pasteLongerSource() throws {
        // 4× quarter rests in 4/4. Paste a half-note chord at idx 2;
        // the algorithm consumes the rest at idx 3 to make room.
        var score = EditingFixtures.fourQuarterRests()
        let halfChord = Chord(
            duration: .half, notes: [Note(pitch: 60, tpc: 14)])
        let cmd = PasteVoiceElement(
            at: Self.restID, element: .chord(halfChord))
        _ = try cmd.apply(to: &score)
        let voice = score.staves[0].measures[0].voices[0]
        // Voice elements: timeSig, rest(q), rest(q), chord(half),
        // (idx 4 was rest(q) — gone, eaten by the half).
        #expect(voice.elements.count == 4)
        guard case .chord(let pasted) = voice.elements[2] else {
            Issue.record("expected chord at idx 2"); return
        }
        #expect(pasted.duration == .half)
        #expect(pasted.notes.first?.pitch == 60)
    }

    @Test("paste a shorter source fills leftover with rests")
    func pasteShorterSource() throws {
        // 4× quarter rests, but replace idx 1 + idx 2 with a single
        // half rest first so we have a half-duration target to paste
        // a quarter onto.
        var score = EditingFixtures.fourQuarterRests()
        var v = score.staves[0].measures[0].voices[0]
        v.elements = [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(Rest(duration: .half)),
            .rest(Rest(duration: .quarter)),
            .rest(Rest(duration: .quarter)),
        ]
        score.staves[0].measures[0].voices[0] = v
        let halfRestID = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 1)
        let quarterChord = Chord(
            duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        let cmd = PasteVoiceElement(
            at: halfRestID, element: .chord(quarterChord))
        _ = try cmd.apply(to: &score)
        let voice = score.staves[0].measures[0].voices[0]
        // [timeSig, chord(quarter), rest(quarter, leftover),
        //  rest(quarter), rest(quarter)] — 5 elements.
        #expect(voice.elements.count == 5)
        guard case .chord(let pasted) = voice.elements[1] else {
            Issue.record("expected chord at idx 1"); return
        }
        #expect(pasted.duration == .quarter)
        guard case .rest(let leftover) = voice.elements[2] else {
            Issue.record("expected leftover rest at idx 2"); return
        }
        #expect(leftover.duration == .quarter)
    }

    @Test("paste refuses when there isn't enough room to lengthen")
    func refusesWhenNotEnoughRoom() {
        // 4/4: 4× quarter. Pasting a whole chord at idx 4 (last
        // quarter) needs to consume 3 more quarters, but there's
        // nothing past idx 4 in the measure.
        var score = EditingFixtures.fourQuarterRests()
        let lastID = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 4)
        let wholeChord = Chord(
            duration: .whole, notes: [Note(pitch: 60, tpc: 14)])
        let cmd = PasteVoiceElement(
            at: lastID, element: .chord(wholeChord))
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }

    @Test("paste skips the duration check for non-timed elements")
    func nonTimedSkipsDurationCheck() throws {
        // Replace a quarter rest with a clef change — non-timed
        // source, no tick obligation.
        var score = EditingFixtures.fourQuarterRests()
        let clef = Clef(concertClefType: "F")
        let cmd = PasteVoiceElement(
            at: Self.restID, element: .clef(clef))
        _ = try cmd.apply(to: &score)
        guard case .clef = score[Self.restID] else {
            Issue.record("not a clef"); return
        }
    }

    @Test("inverse round-trips a paste")
    func inverseRestores() throws {
        var score = EditingFixtures.chordAtIndex1()
        let snapshot = score
        let restElement = VoiceElement.rest(Rest(duration: .quarter))
        let cmd = PasteVoiceElement(
            at: Self.chordID, element: restElement)
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == snapshot)
    }

    @Test("paste throws when location is out of range")
    func refusesOnOutOfRange() {
        var score = EditingFixtures.fourQuarterRests()
        let bogus = VoiceElementID(
            staffIndex: 0, measureIndex: 0,
            voiceIndex: 0, elementIndex: 99)
        let cmd = PasteVoiceElement(
            at: bogus,
            element: .rest(Rest(duration: .quarter)))
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }
}
