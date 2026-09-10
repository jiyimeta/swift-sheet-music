@testable import SheetMusicCore
import Testing

@Suite("Score EID lookup")
struct ScoreEIDLookupTests {
    @Test func everyPositionRoundTripsWithDistinctIdentifiers() throws {
        let score = ScoreEditor(score: literalScore()).score
        let positions = positions(in: score)
        var identifiers = Set<EID>()
        for position in positions {
            let eid = try #require(score.eid(at: position))
            #expect(eid.isValid)
            #expect(score.position(of: eid) == position)
            #expect(score[eid: eid] == score[position])
            #expect(identifiers.insert(eid).inserted)
        }
        #expect(identifiers.count == positions.count)
    }

    @Test func unknownAndInvalidIdentifiersDoNotMatch() {
        let editor = ScoreEditor(score: literalScore())
        var unrelated = EIDAllocator(actor: editor.idAllocator.actor == 42 ? 43 : 42)
        for eid in [unrelated.next(), .invalid] {
            #expect(editor.score.position(of: eid) == nil)
            #expect(editor.score[eid: eid] == nil)
        }
    }

    @Test func outOfRangePositionsReturnNil() {
        let score = ScoreEditor(score: literalScore()).score
        let invalidPositions = [
            position(part: -1), position(part: 2),
            position(staff: -1), position(staff: 2),
            position(measure: -1), position(measure: 2),
            position(voice: -1), position(voice: 2),
            position(element: -1), position(element: 3),
        ]
        for position in invalidPositions {
            #expect(score.eid(at: position) == nil)
        }
    }

    @Test func unassignedSlotsDoNotExposeInvalidIdentifiers() {
        let score = literalScore()
        for position in positions(in: score) {
            #expect(score[position] != nil)
            #expect(score.eid(at: position) == nil)
        }
        #expect(score.position(of: .invalid) == nil)
        #expect(score[eid: .invalid] == nil)
    }

    @Test func identityFollowsMeasureInsertionAndUndo() throws {
        let editor = ScoreEditor(score: literalScore())
        let originalPosition = position(part: 0, staff: 1, measure: 1, voice: 1, element: 2)
        let eid = try #require(editor.score.eid(at: originalPosition))
        let originalElement = try #require(editor.score[originalPosition])
        try editor.apply(InsertMeasure(measureIndex: 0))
        let movedPosition = VoiceElementID(
            staff: originalPosition.staff, measureIndex: originalPosition.measureIndex + 1,
            voiceIndex: originalPosition.voiceIndex, elementIndex: originalPosition.elementIndex,
        )
        #expect(editor.score.position(of: eid) == movedPosition)
        #expect(editor.score.eid(at: movedPosition) == eid)
        #expect(editor.score[eid: eid] == originalElement)
        let displaced = try #require(editor.score.eid(at: originalPosition))
        #expect(displaced != eid)
        try editor.undo()
        #expect(editor.score.position(of: eid) == originalPosition)
        #expect(editor.score.eid(at: originalPosition) == eid)
        #expect(editor.score[eid: eid] == originalElement)
    }

    @Test func removingOwningPartMakesIdentifierAbsent() throws {
        let editor = ScoreEditor(score: literalScore())
        let originalPosition = position(part: 1, measure: 1, element: 2)
        let eid = try #require(editor.score.eid(at: originalPosition))
        try editor.apply(RemovePart(partIndex: originalPosition.staff.partIndex))
        #expect(editor.score.position(of: eid) == nil)
        #expect(editor.score[eid: eid] == nil)
    }

    @Test func nestedGraceChordsAreOutsideLookupScope() throws {
        let score = ScoreEditor(score: literalScore()).score
        let element = try #require(score[position()])
        guard case let .chord(chord) = element else {
            Issue.record("Expected the fixture's first element to be a chord")
            return
        }
        for graces in [chord.graceNotesBefore, chord.graceNotesAfter] {
            #expect(!graces.isEmpty)
            for index in graces.indices {
                let eid = graces.eid(at: index)
                #expect(eid.isValid)
                #expect(score.position(of: eid) == nil)
                #expect(score[eid: eid] == nil)
            }
        }
    }
}

extension ScoreEIDLookupTests {
    private func literalScore() -> Score {
        let grace = GraceChord(
            graceType: .acciaccatura, duration: .eighth, notes: [Note(pitch: 62, tpc: 16)],
        )
        let chord = Chord(
            duration: .quarter, notes: [Note(pitch: 60, tpc: 14)],
            graceNotesBefore: [grace], graceNotesAfter: [grace],
        )
        let voice = Voice(elements: [
            .chord(chord), .rest(duration: .quarter),
            .chord(Chord(duration: .half, notes: [Note(pitch: 64, tpc: 18)])),
        ])
        let staff = Staff(measures: [
            Measure(voices: [voice, voice]), Measure(voices: [voice, voice]),
        ])
        return Score(division: 480, parts: [
            Part(id: "piano", instrument: Instrument(id: "piano"), staves: [staff, staff]),
            Part(id: "flute", instrument: Instrument(id: "flute"), staves: [staff]),
        ], systemMeasures: [SystemMeasure(), SystemMeasure()])
    }

    private func position(
        part: Int = 0, staff: Int = 0, measure: Int = 0, voice: Int = 0, element: Int = 0,
    ) -> VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: part, staffIndexInPart: staff),
            measureIndex: measure, voiceIndex: voice, elementIndex: element,
        )
    }

    private func positions(in score: Score) -> [VoiceElementID] {
        var result: [VoiceElementID] = []
        for (partIndex, part) in score.parts.enumerated() {
            for (staffIndex, staff) in part.staves.enumerated() {
                for (measureIndex, measure) in staff.measures.enumerated() {
                    for (voiceIndex, voice) in measure.voices.enumerated() {
                        for elementIndex in voice.elements.indices {
                            result.append(position(
                                part: partIndex, staff: staffIndex, measure: measureIndex,
                                voice: voiceIndex, element: elementIndex,
                            ))
                        }
                    }
                }
            }
        }
        return result
    }
}
