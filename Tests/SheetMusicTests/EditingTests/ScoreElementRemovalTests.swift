import SheetMusicCore
import Testing

@Suite("ScoreElementID removal resolver")
struct ScoreElementRemovalTests {
    private static let staff = StaffAddress(partIndex: 1, staffIndexInPart: 2)
    private static let anchor = VoiceElementID(staff: staff, measureIndex: 3, voiceIndex: 1, elementIndex: 4)

    @Test("Factories retain every payload without looking up a score")
    func payloads() throws {
        let start = NoteID(
            staff: Self.staff,
            measureIndex: 3,
            voiceIndex: 1,
            elementIndex: 4,
            noteIndexInChord: 2,
        )
        let end = NoteID(
            staff: StaffAddress(partIndex: 2, staffIndexInPart: 0),
            measureIndex: 5,
            voiceIndex: 2,
            elementIndex: 6,
            noteIndexInChord: 1,
        )
        let tie = try #require(ScoreElementID.tie(start: start, end: end).removalCommand as? RemoveTie)
        #expect(tie.start == start && tie.end == end)
        #expect(tie.affectedLocation == Self.anchor)
        let slurs: [SlurID] = [.chord(anchor: Self.anchor, ordinal: 2), .voice(Self.anchor)]
        for id in slurs {
            let slur = try #require(ScoreElementID.slur(id).removalCommand as? RemoveSlur)
            #expect(slur.id == id)
            #expect(slur.affectedLocation == Self.anchor)
        }
        let jump = try #require(ScoreElementID.jump(staff: Self.staff, measureIndex: 3, index: 2)
            .removalCommand as? RemoveJump)
        let marker = try #require(ScoreElementID.marker(staff: Self.staff, measureIndex: 3, index: 2)
            .removalCommand as? RemoveMarker)
        let location = VoiceElementID(staff: Self.staff, measureIndex: 3, voiceIndex: 0, elementIndex: 0)
        #expect(jump.staff == Self.staff && jump.measureIndex == 3 && jump.index == 2)
        #expect(marker.staff == Self.staff && marker.measureIndex == 3 && marker.index == 2)
        #expect(jump.affectedLocation == location && marker.affectedLocation == location)
    }

    @Test("Previous visual kinds, including legacy spanner-slur, remain unsupported")
    func unsupported() {
        let ids: [ScoreElementID] = [
            .dynamic(anchor: Self.anchor), .fermata(anchor: Self.anchor), .breath(anchor: Self.anchor),
            .tempo(anchor: Self.anchor), .keySignature(measureIndex: 3), .timeSignature(measureIndex: 3),
            .barLine(measureIndex: 3, role: .explicit), .articulation(anchor: Self.anchor, kind: .accent),
        ]
        for id in ids {
            #expect(id.removalCommand == nil)
        }
        let kinds: [Spanner.Kind] = [.hairpin, .pedal, .ottava, .volta, .slur]
        for kind in kinds {
            #expect(ScoreElementID.spanner(anchor: Self.anchor, kind: kind).removalCommand == nil)
        }
    }

    @Test("Supported identities with missing owners produce commands, which refuse on apply")
    func missingOwners() throws {
        let note = NoteID(
            staff: Self.staff,
            measureIndex: 3,
            voiceIndex: 1,
            elementIndex: 4,
            noteIndexInChord: 0,
        )
        let ids: [ScoreElementID] = [
            .tie(start: note, end: note), .slur(.chord(anchor: Self.anchor, ordinal: 0)),
            .slur(.voice(Self.anchor)), .jump(staff: Self.staff, measureIndex: 3, index: 0),
            .marker(staff: Self.staff, measureIndex: 3, index: 0),
        ]
        for id in ids {
            var score = ScoreEditor(score: Score(division: 480)).score
            let before = score
            let command = try #require(id.removalCommand)
            #expect(throws: SheetMusicError.self) { _ = try command.apply(to: &score) }
            #expect(score == before)
        }
    }
}
