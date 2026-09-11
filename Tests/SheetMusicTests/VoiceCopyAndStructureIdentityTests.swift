@testable import SheetMusicCore
import Testing

@Suite("Voice copy and structural identity classification")
struct VoiceCopyAndStructureIdentityTests {
    private typealias Fixture = VoiceIdentityFixtures

    @Test func pasteCreatesDistinctIdentity() throws {
        let editor = ScoreEditor(score: Fixture.score(elements: [
            Fixture.chord(), .rest(duration: .quarter), .rest(duration: .half),
        ]))
        let before = editor.score
        let initial = editor.idAllocator
        let old = Fixture.ids(Fixture.elements(before))
        let copied = Fixture.elements(before)[0]
        try editor.apply(PasteVoiceElement(at: Fixture.location(1), element: copied))
        let result = Fixture.elements(editor.score)
        #expect(result.values == [copied, copied, .rest(duration: .half)])
        // The slot's own EID mints first (unaffected), then the widened nested walk mints the chord's own
        // note — `clearNestedIDsForCopy` no longer lets a paste keep the source's note identifier.
        #expect(Fixture.ids(result) == [old[0], Fixture.minted(initial, 1), old[2]])
        #expect(result.eid(at: 1) != old[0])
        #expect(result.eid(at: 1) != old[1])
        guard case let .chord(sourceChord) = copied, case let .chord(pastedChord) = result[1] else {
            Issue.record("fixture is a chord")
            return
        }
        #expect(pastedChord.notes.eid(at: 0) == Fixture.minted(initial, 2))
        #expect(pastedChord.notes.eid(at: 0) != sourceChord.notes.eid(at: 0))
        #expect(editor.idAllocator == Fixture.advanced(initial, by: 2))
        try editor.undo()
        Fixture.expectSameScore(editor.score, before)
    }

    @Test func insertFirstMeasureCarriesSignatureIdentities() throws {
        let prefix: [VoiceElement] = [
            .clef(Clef(concertClefType: "G")), .keySignature(KeySignature(concertKey: 0)), Fixture.time,
        ]
        let editor = ScoreEditor(score: Fixture.score(elements: prefix + [.rest(duration: .measure)]))
        let before = editor.score
        let initial = editor.idAllocator
        let old = Fixture.ids(Fixture.elements(before))
        let columnID = before.systemMeasures.eid(at: 0)
        try editor.apply(InsertMeasure(measureIndex: 0))
        #expect(editor.score.parts[0].staves[0].measures.count == 2)
        #expect(Fixture.elements(editor.score).values == prefix + [.rest(duration: .measure)])
        #expect(Fixture.ids(Fixture.elements(editor.score)) == [old[0], old[1], old[2], Fixture.minted(initial, 1)])
        #expect(Fixture.elements(editor.score, measure: 1).values == [.rest(duration: .measure)])
        #expect(Fixture.ids(Fixture.elements(editor.score, measure: 1)) == [old[3]])
        #expect(editor.score.systemMeasures.count == 2)
        #expect(editor.score.systemMeasures.eid(at: 0) == Fixture.minted(initial, 2))
        #expect(editor.score.systemMeasures.eid(at: 1) == columnID)
        #expect(editor.idAllocator == Fixture.advanced(initial, by: 2))
        try editor.undo()
        Fixture.expectSameScore(editor.score, before)
    }

    @Test func rebarKeepsExistingTimeSignatureIdentity() throws {
        let editor = ScoreEditor(score: Fixture.score(elements: [
            Fixture.time, Fixture.chord(), Fixture.chord(), Fixture.chord(), Fixture.chord(),
        ]))
        let before = editor.score
        let initial = editor.idAllocator
        let old = Fixture.ids(Fixture.elements(before))
        let columnID = before.systemMeasures.eid(at: 0)
        try editor.apply(SetTimeSignature(measureIndex: 0, numerator: 2, denominator: 4))
        #expect(editor.score.parts[0].staves[0].measures.count == 2)
        #expect(Fixture.voiceIDs(editor.score) == [[old[0], old[1], old[2]], [old[3], old[4]]])
        #expect(Fixture.elements(editor.score).values == [
            .timeSignature(TimeSignature(numerator: 2, denominator: 4)), Fixture.chord(), Fixture.chord(),
        ])
        #expect(Fixture.elements(editor.score, measure: 1).values == [Fixture.chord(), Fixture.chord()])
        #expect(editor.score.systemMeasures.count == 2)
        #expect(editor.score.systemMeasures.eid(at: 0) == columnID)
        #expect(editor.score.systemMeasures.eid(at: 1) == Fixture.minted(initial, 1))
        #expect(editor.idAllocator == Fixture.advanced(initial, by: 1))
        try editor.undo()
        Fixture.expectSameScore(editor.score, before)
    }

    @Test func rebarKeepsWholeMeasureRestIdentity() throws {
        let editor = ScoreEditor(score: Fixture.score(elements: [Fixture.time, .rest(duration: .measure)]))
        let before = editor.score
        let initial = editor.idAllocator
        let old = Fixture.ids(Fixture.elements(before))
        let columnID = before.systemMeasures.eid(at: 0)
        // The 1920-tick rest is cut into two 960-tick halves, then each column promotes its half to .measure.
        // Promotion keeps R on the first column. The second rest mints N1; the new column later mints N2.
        try editor.apply(SetTimeSignature(measureIndex: 0, numerator: 2, denominator: 4))
        #expect(editor.score.parts[0].staves[0].measures.count == 2)
        #expect(Fixture.voiceIDs(editor.score) == [[old[0], old[1]], [Fixture.minted(initial, 1)]])
        #expect(Fixture.elements(editor.score).values == [
            .timeSignature(TimeSignature(numerator: 2, denominator: 4)), .rest(duration: .measure),
        ])
        #expect(Fixture.elements(editor.score, measure: 1).values == [.rest(duration: .measure)])
        #expect(editor.score.systemMeasures.count == 2)
        #expect(editor.score.systemMeasures.eid(at: 0) == columnID)
        #expect(editor.score.systemMeasures.eid(at: 1) == Fixture.minted(initial, 2))
        #expect(editor.idAllocator == Fixture.advanced(initial, by: 2))
        try editor.undo()
        Fixture.expectSameScore(editor.score, before)
    }
}
