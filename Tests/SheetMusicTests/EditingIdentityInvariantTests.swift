import Foundation
@testable import SheetMusicCore
import Testing

@Suite("Editing identity invariants")
struct EditingIdentityInvariantTests {
    private func score() -> Score {
        let measure = Measure(voices: [Voice(elements: [.rest(duration: .whole)])])
        return Score(division: 480, parts: [
            Part(id: "1", instrument: Instrument(id: "piano"), staves: [Staff(measures: [measure, measure])]),
        ], systemMeasures: [SystemMeasure(), SystemMeasure()])
    }

    @Test func shrinkingRebarUndoRestoresColumnIdentifiersInOrderAndAsASet() throws {
        let editor = ScoreEditor(score: score())
        let original = editor.score.systemMeasures.indices.map { editor.score.systemMeasures.eid(at: $0) }
        let initialCounter = editor.idAllocator.counter
        try editor.apply(SetTimeSignature(measureIndex: 0, numerator: 8, denominator: 4))
        // Two whole-note bars become one 8/4 bar; the first column survives.
        #expect(editor.score.systemMeasures.count == 1)
        #expect(editor.score.systemMeasures.eid(at: 0) == original[0])
        let counter = editor.idAllocator.counter
        // The collapsed rest keeps its onset ID; only the new time signature is minted.
        #expect(counter == initialCounter + 1)
        try editor.undo()
        let restored = editor.score.systemMeasures.indices.map { editor.score.systemMeasures.eid(at: $0) }
        // Restoration reuses both original IDs and consumes no allocator counter.
        #expect(restored == original)
        #expect(Set(restored) == Set(original))
        #expect(editor.idAllocator.counter == counter)
    }

    #if DEBUG
        private func singleChordWithGrace() -> Score {
            GraceIdentityFixtures.score(before: [GraceIdentityFixtures.grace()], after: [])
        }

        @Test("the identifier traversal includes chord and grace notes")
        func traversalIncludesNotes() {
            let editor = ScoreEditor(score: singleChordWithGrace())
            guard case let .chord(chord) = editor.score.parts[0].staves[0].measures[0].voices[0].elements[0]
            else { fatalError("fixture is a chord") }
            let noteID = chord.notes.eid(at: 0)
            let graceNoteID = chord.graceNotesBefore[0].notes.eid(at: 0)
            let collected = Set(EditingIdentityInvariants.identifiers(in: editor.score))
            #expect(collected.contains(noteID))
            #expect(collected.contains(graceNoteID))
        }

        // Containment alone (above) only shows the traversal reports a note identifier when one
        // exists; it says nothing about whether the gate can actually catch a collision at the note
        // level. These three tests force a collision directly on `ChordNotes.ids` — internal, but
        // reachable through `@testable import` — deliberately bypassing `noteIdentifiers(of:)` and
        // every other production mutation path, so a pass here is independent evidence about the
        // traversal's discriminating power rather than a restatement of it.

        @Test("hasUniqueIDs rejects two notes within one chord sharing an identifier")
        func noteCollisionWithinOneChordIsRejected() {
            var score = ScoreEditor(score: VoiceIdentityFixtures.score(elements: [
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14), Note(pitch: 64, tpc: 18)])),
            ])).score
            #expect(EditingIdentityInvariants.hasUniqueIDs(score))
            GraceIdentityFixtures.mutate(&score) { chord in
                chord.notes.ids[1] = chord.notes.ids[0]
            }
            #expect(!EditingIdentityInvariants.hasUniqueIDs(score))
        }

        @Test("hasUniqueIDs rejects a chord's note sharing an identifier with its own grace's note")
        func noteCollisionWithOwnGraceIsRejected() {
            var score = ScoreEditor(score: singleChordWithGrace()).score
            #expect(EditingIdentityInvariants.hasUniqueIDs(score))
            GraceIdentityFixtures.mutate(&score) { chord in
                let noteID = chord.notes.eid(at: 0)
                chord.graceNotesBefore.updateValue(at: 0) { grace in
                    grace.notes.ids[0] = noteID
                }
            }
            #expect(!EditingIdentityInvariants.hasUniqueIDs(score))
        }

        @Test("hasUniqueIDs rejects notes in two different chords sharing an identifier")
        func noteCollisionAcrossChordsIsRejected() {
            var score = ScoreEditor(score: VoiceIdentityFixtures.score(elements: [
                VoiceIdentityFixtures.chord(pitch: 60), VoiceIdentityFixtures.chord(pitch: 64),
            ])).score
            #expect(EditingIdentityInvariants.hasUniqueIDs(score))
            guard case let .chord(first) = VoiceIdentityFixtures.elements(score)[0]
            else { fatalError("fixture is a chord") }
            let firstNoteID = first.notes.eid(at: 0)
            GraceIdentityFixtures.mutate(&score, index: 1) { chord in
                chord.notes.ids[0] = firstNoteID
            }
            #expect(!EditingIdentityInvariants.hasUniqueIDs(score))
        }

        @Test("allocatorCovers rejects a note identifier forged outside the allocator's range")
        func allocatorCoverageIncludesNoteHighWater() {
            var score = singleChordWithGrace()
            var ids = EIDAllocator(actor: 42)
            score.assignMissingIDs(using: &ids)
            #expect(EditingIdentityInvariants.allocatorCovers(score, ids))
            // Any counter value past the live high-water mark is out of range by construction —
            // no need to hand-derive the exact mint count, unlike the duplicate-collision tests
            // above where the forged id must equal an existing one.
            let forged = EID(first: ids.actor, second: ids.counter + 1)
            GraceIdentityFixtures.mutate(&score) { chord in
                chord.notes.ids[0] = forged
            }
            #expect(!score.hasUnassignedIDs)
            #expect(EditingIdentityInvariants.hasUniqueIDs(score))
            #expect(!EditingIdentityInvariants.allocatorCovers(score, ids))
        }

        @Test func duplicateCheckerRejectsRealDuplicateSlots() {
            let eid = EID(first: 42, second: 1)
            let duplicate = Score(division: 480, parts: IdentifiedArray([
                (EID(first: 42, second: 2), Part(
                    id: "1", instrument: Instrument(id: "piano"),
                    staves: IdentifiedArray([(eid, Staff())]),
                )),
                (EID(first: 42, second: 3), Part(
                    id: "2", instrument: Instrument(id: "piano"),
                    staves: IdentifiedArray([(eid, Staff())]),
                )),
            ]))
            // Pair initialization refuses within-array duplicates; the gate must catch cross-array duplicates.
            #expect(duplicate.parts[0].staves.count == 1)
            #expect(duplicate.parts[1].staves.count == 1)
            #expect(!EditingIdentityInvariants.hasUniqueIDs(duplicate))
            let unique = Score(division: 480, systemMeasures: IdentifiedArray([
                (eid, SystemMeasure()), (EID(first: 42, second: 2), SystemMeasure()),
            ]))
            #expect(EditingIdentityInvariants.hasUniqueIDs(unique))
            var crossLane = score()
            var ids = EIDAllocator(actor: 42)
            crossLane.assignMissingIDs(using: &ids)
            #expect(EditingIdentityInvariants.hasUniqueIDs(crossLane))
            let partID = crossLane.parts.eid(at: 0)
            crossLane.parts.updateValue(at: 0) { part in
                part.staves = IdentifiedArray([(partID, part.staves[0])])
            }
            // Part and staff now share an ID: uniqueness must span collection boundaries too.
            #expect(!EditingIdentityInvariants.hasUniqueIDs(crossLane))
        }

        @Test func undoSetCheckerRejectsDifferentSets() {
            let before: Set<EID> = [EID(first: 42, second: 1)]
            let different: Set<EID> = [EID(first: 42, second: 2)]
            // {1} differs from {2}, but is equal to itself.
            #expect(!EditingIdentityInvariants.restoresIDs(before, after: different))
            #expect(EditingIdentityInvariants.restoresIDs(before, after: before))
        }

        @Test func allFourSeamsExecuteTheirChecks() throws {
            let before = EditingIdentityInvariants.counts
            let editor = ScoreEditor(score: score())
            try editor.apply(InsertMeasure(measureIndex: 1))
            try editor.undo()
            try editor.redo()
            try editor.undo()
            var bare = score()
            try InsertMeasure(measureIndex: 1).apply(to: &bare)
            let after = EditingIdentityInvariants.counts
            // This route adds (apply: 1, undo: 2, redo: 1, bare: 1).
            // Parallel tests can only increase the global totals further.
            #expect(after.apply >= before.apply + 1)
            #expect(after.undo >= before.undo + 2)
            #expect(after.redo >= before.redo + 1)
            #expect(after.bare >= before.bare + 1)
            print("Identity gate counts at observation: \(after)")
        }
    #endif

    private func callsBareApply(_ source: String) -> Bool {
        source.range(
            of: #"\.apply\s*\(\s*to\s*:\s*&[A-Za-z_][A-Za-z_0-9.]*\s*\)"#,
            options: .regularExpression,
        ) != nil
    }

    @Test func sourceMatcherRejectsOnlyTheBareForm() {
        // The bare call matches; threading ids and unrelated text do not.
        #expect(callsBareApply("try command.apply(to: &score)"))
        #expect(callsBareApply("try command.apply(\n to: &working.score\n)"))
        #expect(!callsBareApply("try command.apply(to: &score, ids: &ids)"))
        #expect(!callsBareApply("let score = Score(division: 480)"))
    }

    // Host-only: this walks the checked-out source tree through `#filePath`, which exists on the
    // machine that checked the repository out and nowhere else. Under WASI and on an Android device
    // there is no such tree, and `subpathsOfDirectory` fails with "The file doesn't exist" — a
    // failure about the sandbox, not about the guarded property. The matcher's own test above is
    // pure string work and deliberately stays unguarded, so the part that can be wrong everywhere
    // is still checked everywhere.
    #if !os(Android) && !os(WASI)
        @Test func productionSourcesNeverCallTheBareConvenience() throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let sources = root.appendingPathComponent("Sources")
            let paths = try FileManager.default.subpathsOfDirectory(atPath: sources.path)
                .filter { $0.hasSuffix(".swift") }.sorted()
            // A missing/empty source tree must not turn this guard into a vacuous pass.
            #expect(!paths.isEmpty)
            var violations: [String] = []
            for path in paths {
                let source = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
                if callsBareApply(source) { violations.append(path) }
            }
            #expect(violations.isEmpty)
            print("Ruling E guard scanned \(paths.count) Swift files; violations: \(violations.count)")
        }
    #endif
}
