@testable import SheetMusicCore
import Testing

@Suite("Tuplet identity prefix splices")
struct TupletIdentityPrefixTests {
    private typealias F = TupletIdentityFixtures
    private typealias V = VoiceIdentityFixtures

    @Test(arguments: [false, true])
    func insertingInitialMeasureRetargetsOrDropsPrefixTupletAndUndoRestoresIt(markOnly: Bool) throws {
        let editor = ScoreEditor(score: F.score([
            .clef(Clef(concertClefType: "G")), V.chord(), V.chord(),
        ], tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: markOnly ? 0 : 2)]))
        let before = editor.score
        let old = F.voice(before)
        try editor.apply(InsertMeasure(measureIndex: 0))
        let voice = F.voice(editor.score, measure: 1)
        #expect(F.voice(editor.score).tuplets.isEmpty)
        #expect(F.voice(editor.score).elements.eid(at: 0) == old.elements.eid(at: 0))
        if markOnly {
            #expect(voice.tuplets.isEmpty)
        } else {
            #expect(voice.tuplets.eid(at: 0) == old.tuplets.eid(at: 0))
            #expect(voice.tuplets[0].first == .element(old.elements.eid(at: 1)))
            #expect(voice.tuplets[0].last == .element(old.elements.eid(at: 2)))
        }
        try F.expectRoundTrip(editor, before: before, after: editor.score)
    }

    @Test func deletingInitialMeasureKeepsIncomingPrefixEndpointThroughMerge() throws {
        let first = Voice(elements: [.keySignature(KeySignature(concertKey: 2)), .rest(duration: .measure)])
        let incoming = Voice(elements: [.clef(Clef(concertClefType: "G")), V.chord(), V.chord()], tuplets: [F.triplet])
        let editor = ScoreEditor(score: V.score([[first], [incoming]]))
        let before = editor.score
        let old = F.voice(before, measure: 1)
        try editor.apply(DeleteMeasure(measureIndex: 0))
        let voice = F.voice(editor.score)
        #expect(voice.tuplets[0] == old.tuplets[0])
        #expect(voice.tuplets.eid(at: 0) == old.tuplets.eid(at: 0))
        #expect(voice.tupletSpans[0].startIndex == 0)
        #expect(voice.tupletSpans[0].endIndex == 3)
        try F.expectRoundTrip(editor, before: before, after: editor.score)
    }

    @Test func irregularTimeInsertionKeepsClefEndpointAndUndoRestoresIt() throws {
        var score = F.score([.clef(Clef(concertClefType: "G")), V.chord(), V.chord()])
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[0].actualLength = Fraction(numerator: 1, denominator: 2)
            }
        }
        let editor = ScoreEditor(score: score)
        let before = editor.score
        try editor.apply(SetTimeSignature(measureIndex: 0, numerator: 3, denominator: 4))
        let voice = F.voice(editor.score)
        #expect(voice.tuplets[0] == F.voice(before).tuplets[0])
        #expect(voice.tuplets.eid(at: 0) == F.voice(before).tuplets.eid(at: 0))
        #expect(voice.tupletSpans[0].startIndex == 0)
        #expect(voice.tupletSpans[0].endIndex == 3)
        try F.expectRoundTrip(editor, before: before, after: editor.score)
    }

    @Test(arguments: [false, true])
    func irregularTimeEndpointRemovalRestoresExactTuplet(markOnly: Bool) throws {
        let incoming = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 3, denominator: 4)), V.chord(), V.chord(),
        ], tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: markOnly ? 0 : 2)])
        var score = V.score([[Voice(elements: [V.time, .rest(duration: .measure)])], [incoming]])
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[1].actualLength = Fraction(numerator: 1, denominator: 2)
            }
        }
        let editor = ScoreEditor(score: score)
        let before = editor.score
        try editor.apply(RemoveTimeSignature(measureIndex: 1))
        let voice = F.voice(editor.score, measure: 1)
        if markOnly {
            #expect(voice.tuplets.isEmpty)
        } else {
            #expect(voice.tuplets.eid(at: 0) == F.voice(before, measure: 1).tuplets.eid(at: 0))
            #expect(voice.tuplets[0].first == .element(voice.elements.eid(at: 0)))
            #expect(voice.tuplets[0].last == .element(voice.elements.eid(at: 1)))
        }
        try F.expectRoundTrip(editor, before: before, after: editor.score)
    }

    @Test func rebarCarriesOuterEntryAndUndoRestoresDroppedNestedIdentity() throws {
        let editor = ScoreEditor(score: F.score([
            V.chord(), V.chord(), V.chord(), .rest(duration: .quarter),
        ], tuplets: [F.triplet, Tuplet(normalNotes: 4, actualNotes: 5, startIndex: 1, endIndex: 2)]))
        let before = editor.score
        let old = F.voice(before)
        try editor.apply(SetTimeSignature(measureIndex: 0, numerator: 4, denominator: 4))
        let voice = F.voice(editor.score)
        #expect(voice.tuplets.count == 1)
        #expect(voice.tuplets.eid(at: 0) == old.tuplets.eid(at: 0))
        #expect(voice.tuplets[0] == old.tuplets[0])
        #expect(voice.tupletSpans[0].startIndex == 1)
        #expect(voice.tupletSpans[0].endIndex == 3)
        try F.expectRoundTrip(editor, before: before, after: editor.score)
    }
}
