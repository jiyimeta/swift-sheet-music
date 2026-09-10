@testable import SheetMusicCore
import Testing

@Suite("Voice element identity")
struct VoiceElementIdentityTests {
    private let location = VoiceElementID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
        measureIndex: 0, voiceIndex: 0, elementIndex: 0,
    )

    private func chord(_ pitch: Int = 60) -> VoiceElement {
        .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: 14)]))
    }

    private func score(_ elements: [VoiceElement], tuplets: [Tuplet] = []) -> Score {
        Score(division: 480, parts: [Part(
            id: "P1", instrument: Instrument(id: "piano"),
            staves: [Staff(measures: [Measure(voices: [Voice(elements: elements, tuplets: tuplets)])])],
        )])
    }

    private func elements(_ score: Score) -> IdentifiedArray<VoiceElement> {
        score.parts[0].staves[0].measures[0].voices[0].elements
    }

    private func identifiers(_ score: Score) -> [EID] {
        let slots = elements(score)
        return slots.indices.map { slots.eid(at: $0) }
    }

    @Test func editorAssignsLiteralVoiceSlots() {
        let original = score([
            chord(), .rest(duration: .quarter), .locationShift(delta: Fraction(numerator: 0, denominator: 1)),
            .preserved(PreservedXML(name: "unknown")),
        ])
        #expect(elements(original).hasUnassignedIDs)
        let editor = ScoreEditor(score: original)
        #expect(!editor.score.hasUnassignedIDs)
        // Outside the macro: `#expect` rewrites the call and cannot resolve `allSatisfy`'s `rethrows`.
        let everySlotAssigned = identifiers(editor.score).allSatisfy(\.isValid)
        #expect(everySlotAssigned)
        #expect(Set(identifiers(editor.score)).count == 4)
    }

    @Test func bareApplyAssignsLiteralVoiceSlots() throws {
        var score = score([chord(), .rest(duration: .quarter)])
        #expect(elements(score).hasUnassignedIDs)
        try ReplaceVoiceElement(at: location, with: chord(62)).apply(to: &score)
        #expect(elements(score)[0] == chord(62))
        #expect(!score.hasUnassignedIDs)
        #expect(Set(identifiers(score)).count == 2)
    }

    @Test func sameChangesValueAndItsInverseKeepsIdentity() throws {
        var score = score([chord()])
        var ids = EIDAllocator(actor: 42)
        score.assignMissingIDs(using: &ids)
        let before = identifiers(score)
        let inverse = try ReplaceVoiceElement(at: location, with: chord(62), identity: .same)
            .apply(to: &score, ids: &ids)
        #expect(elements(score)[0] == chord(62))
        #expect(identifiers(score) == before)
        try inverse.apply(to: &score, ids: &ids)
        #expect(elements(score)[0] == chord())
        #expect(identifiers(score) == before)
    }

    @Test func freshChangesIdentityAndInverseRestoresIt() throws {
        var score = score([.rest(duration: .quarter)])
        var ids = EIDAllocator(actor: 42)
        score.assignMissingIDs(using: &ids)
        let before = identifiers(score)
        let inverse = try ReplaceVoiceElement(at: location, with: chord(), identity: .fresh)
            .apply(to: &score, ids: &ids)
        #expect(elements(score)[0] == chord())
        #expect(identifiers(score) != before)
        try inverse.apply(to: &score, ids: &ids)
        #expect(elements(score)[0].isRest)
        #expect(identifiers(score) == before)
    }

    @Test func restoreSetsNamedIdentityAndInverseRestoresPreviousSlot() throws {
        var score = score([chord()])
        var ids = EIDAllocator(actor: 42)
        score.assignMissingIDs(using: &ids)
        let before = identifiers(score)
        let restored = EID(first: 99, second: 1)
        let inverse = try ReplaceVoiceElement(at: location, with: chord(62), identity: .restore(restored))
            .apply(to: &score, ids: &ids)
        #expect(elements(score)[0] == chord(62))
        #expect(identifiers(score) == [restored])
        try inverse.apply(to: &score, ids: &ids)
        #expect(elements(score)[0] == chord())
        #expect(identifiers(score) == before)
    }

    @Test func voicePayloadMintsOnlyFreshSlotsAtApply() throws {
        var score = score([chord()])
        var ids = EIDAllocator(actor: 42)
        score.assignMissingIDs(using: &ids)
        let before = identifiers(score)
        let counter = ids.counter
        let command = ReplaceVoiceElements(
            staff: location.staff, measureIndex: 0, voiceIndex: 0,
            slots: [
                VoiceSlot(identity: .fresh, element: chord(62)),
                VoiceSlot(identity: .keep(before[0]), element: chord()),
                VoiceSlot(identity: .fresh, element: .rest(duration: .quarter)),
            ],
        )
        #expect(ids.counter == counter)
        let inverse = try command.apply(to: &score, ids: &ids)
        #expect(ids.counter == counter + 2)
        #expect(elements(score).values == [chord(62), chord(), .rest(duration: .quarter)])
        #expect(elements(score).eid(at: 1) == before[0])
        let created = Set(identifiers(score)).subtracting(before)
        #expect(created.count == 2)
        try inverse.apply(to: &score, ids: &ids)
        #expect(elements(score).values == [chord()])
        #expect(identifiers(score) == before)
        #expect(Set(identifiers(score)).isDisjoint(with: created))
    }

    @Test func deleteUndoRestoresChordIdentity() throws {
        let editor = ScoreEditor(score: score([chord()]))
        let before = identifiers(editor.score)
        try editor.apply(DeleteVoiceElement(at: location))
        #expect(elements(editor.score)[0].isRest)
        #expect(identifiers(editor.score) != before)
        try editor.undo()
        #expect(elements(editor.score)[0] == chord())
        #expect(identifiers(editor.score) == before)
    }

    @Test func articulationChangesValueAndKeepsIdentity() throws {
        let editor = ScoreEditor(score: score([chord()]))
        let before = identifiers(editor.score)
        try editor.apply(SetArticulation(at: location, kind: .staccato, anchor: nil, present: true))
        #expect(elements(editor.score)[0] != chord())
        #expect(identifiers(editor.score) == before)
    }

    @Test func splitRestKeepsOnlyOnsetPieceIdentity() throws {
        let editor = ScoreEditor(score: score([.rest(duration: .whole)]))
        let before = identifiers(editor.score)
        try editor.apply(SplitRest(at: location, tickOffset: 480))
        #expect(elements(editor.score).count > 1)
        #expect(elements(editor.score)[0] == .rest(duration: .quarter))
        #expect(elements(editor.score).eid(at: 0) == before[0])
        #expect(!identifiers(editor.score).dropFirst().contains(before[0]))
        try editor.undo()
        #expect(elements(editor.score).values == [.rest(duration: .whole)])
        #expect(identifiers(editor.score) == before)
    }

    @Test func removingTupletKeepsTheSoundingMemberThatMovesToTheFront() throws {
        let editor = ScoreEditor(score: score(
            [.rest(duration: .quarter), chord(), chord(64)],
            tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: 2)],
        ))
        let before = identifiers(editor.score)
        try editor.apply(RemoveTuplet(at: location))
        #expect(elements(editor.score).count == 1)
        guard case let .chord(result) = elements(editor.score)[0] else {
            Issue.record("expected the first sounding member"); return
        }
        #expect(result.notes.first?.pitch == 60)
        #expect(result.duration != .quarter)
        #expect(identifiers(editor.score) == [before[1]])
        try editor.undo()
        #expect(elements(editor.score).values == [.rest(duration: .quarter), chord(), chord(64)])
        #expect(identifiers(editor.score) == before)
    }

    private func score() -> Score {
        let voice = Voice(elements: [.rest(duration: .quarter), .rest(duration: .quarter)])
        let measure = Measure(voices: [voice, voice])
        let staff = Staff(measures: [measure, measure])
        return Score(division: 480, parts: [
            Part(id: "1", instrument: Instrument(id: "piano"), staves: [staff, staff]),
            Part(id: "2", instrument: Instrument(id: "piano"), staves: [staff, staff]),
        ], systemMeasures: [SystemMeasure(), SystemMeasure()])
    }

    @Test func deletingRestKeepsItsValueAndIdentity() throws {
        let editor = ScoreEditor(score: score())
        let before = editor.score.parts[0].staves[0].measures[0].voices[0].elements
        let counter = editor.idAllocator.counter
        try editor.apply(DeleteVoiceElement(at: location))
        let after = editor.score.parts[0].staves[0].measures[0].voices[0].elements
        #expect(before[0].isRest)
        #expect(after[0] == before[0])
        #expect(after.eid(at: 0) == before.eid(at: 0))
        #expect(editor.idAllocator.counter == counter)
    }

    @Test func creatingVoiceRedoRestoresItsRestWithoutMinting() throws {
        let editor = ScoreEditor(score: score())
        let initialCounter = editor.idAllocator.counter
        try editor.apply(CreateVoice(staff: location.staff, measureIndex: 0, voiceIndex: 2))
        let created = editor.score.parts[0].staves[0].measures[0].voices[2].elements
        #expect(created.values == [.rest(duration: .measure)])
        #expect(editor.idAllocator.counter == initialCounter + 1)
        try editor.undo()
        #expect(editor.score.parts[0].staves[0].measures[0].voices.count == 2)
        let counter = editor.idAllocator.counter
        try editor.redo()
        let restored = editor.score.parts[0].staves[0].measures[0].voices[2].elements
        #expect(restored.values == created.values)
        #expect(restored.eid(at: 0) == created.eid(at: 0))
        #expect(editor.idAllocator.counter == counter)
    }

    @Test func oneUnassignedVoiceSlotIsDetectedDespiteAnAssignedSpine() {
        var score = ScoreEditor(score: score()).score
        #expect(!score.hasUnassignedIDs)
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                var elements = staff.measures[0].voices[1].elements
                elements = IdentifiedArray([
                    (.invalid, elements[0]), (elements.eid(at: 1), elements[1]),
                ])
                staff.measures[0].voices[1].elements = elements
            }
        }
        #expect(score.hasUnassignedIDs)
    }

    #if DEBUG
        @Test func redoComparisonRejectsAnInverseThatRemints() throws {
            var score = score()
            var ids = EIDAllocator(actor: 42)
            score.assignMissingIDs(using: &ids)
            let original = Set(EditingIdentityInvariants.identifiers(in: score))
            let undo = try RemintingVoiceSlot().apply(to: &score, ids: &ids)
            let firstApply = Set(EditingIdentityInvariants.identifiers(in: score))
            #expect(firstApply != original)
            let redo = try undo.apply(to: &score, ids: &ids)
            #expect(Set(EditingIdentityInvariants.identifiers(in: score)) == original)
            // Deliberately bypass ScoreEditor: its new assert would terminate this test.
            try redo.apply(to: &score, ids: &ids)
            let secondApply = Set(EditingIdentityInvariants.identifiers(in: score))
            #expect(!EditingIdentityInvariants.restoresIDs(firstApply, after: secondApply))
        }

        @Test func identifierTraversalReachesEveryVoiceSlot() {
            let score = ScoreEditor(score: score()).score
            var voiceIDs: [EID] = []
            var spineIDs = score.parts.indices.map { score.parts.eid(at: $0) }
            for part in score.parts {
                spineIDs.append(contentsOf: part.staves.indices.map { part.staves.eid(at: $0) })
                for staff in part.staves {
                    for measure in staff.measures {
                        for voice in measure.voices {
                            for index in voice.elements.indices {
                                voiceIDs.append(voice.elements.eid(at: index))
                            }
                        }
                    }
                }
            }
            spineIDs.append(contentsOf: score.systemMeasures.indices.map { score.systemMeasures.eid(at: $0) })
            let reported = EditingIdentityInvariants.identifiers(in: score)
            #expect(voiceIDs.count == 32)
            #expect(reported.count == spineIDs.count + voiceIDs.count)
            #expect(Set(reported).subtracting(spineIDs) == Set(voiceIDs))
        }

        @Test func duplicateCheckerReachesAcrossVoices() {
            var score = ScoreEditor(score: score()).score
            #expect(EditingIdentityInvariants.hasUniqueIDs(score))
            score.parts.updateValue(at: 0) { part in
                part.staves.updateValue(at: 0) { staff in
                    let shared = staff.measures[0].voices[0].elements.eid(at: 0)
                    for index in 0 ..< 2 {
                        let elements = staff.measures[0].voices[index].elements
                        staff.measures[0].voices[index].elements = IdentifiedArray([
                            (shared, elements[0]), (elements.eid(at: 1), elements[1]),
                        ])
                    }
                }
            }
            #expect(!score.hasUnassignedIDs)
            #expect(!EditingIdentityInvariants.hasUniqueIDs(score))
        }
    #endif
}

#if DEBUG
    /// Broken on purpose: undo restores the old ID, but returns a redo that mints again.
    private struct RemintingVoiceSlot: EditCommand {
        var restoring: EID?

        var affectedLocation: VoiceElementID {
            VoiceElementID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 0, voiceIndex: 0, elementIndex: 0,
            )
        }

        @discardableResult
        func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
            let previous = score.parts[0].staves[0].measures[0].voices[0].elements.eid(at: 0)
            let replacement = restoring ?? ids.next()
            score.parts.updateValue(at: 0) { part in
                part.staves.updateValue(at: 0) { staff in
                    var elements = staff.measures[0].voices[0].elements
                    elements.replace(at: previous, with: elements[0], newEID: replacement)
                    staff.measures[0].voices[0].elements = elements
                }
            }
            return RemintingVoiceSlot(restoring: restoring == nil ? previous : nil)
        }
    }
#endif
