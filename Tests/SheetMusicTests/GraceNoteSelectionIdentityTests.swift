import Foundation
@testable import SheetMusicCore
import SheetMusicEditWire
import SheetMusicLayout
import Testing

/// `GraceNoteID` as a selection item: its positional answers, its lookups, and every place a selection identity is
/// re-addressed or carried — the filtered-staff re-stamp in both directions, the editing address map, the wire and
/// the selection expansion a renderer tints from.
@Suite("Grace note — selection identity")
struct GraceNoteSelectionIdentityTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let staff1 = StaffAddress(partIndex: 0, staffIndexInPart: 1)

    private static func grace(_ pitch: Int, tpc: Int, type: GraceType = .acciaccatura) -> GraceChord {
        GraceChord(graceType: type, duration: .eighth, notes: [Note(pitch: pitch, tpc: tpc)])
    }

    /// One bar: a clef, then C4 carrying before-graces D4 and E4, then D4 carrying an after-grace F4, then a rest.
    private static func voice() -> Voice {
        Voice(elements: [
            .clef(Clef(concertClefType: "G")),
            .chord(Chord(
                duration: .quarter, notes: [Note(pitch: 60, tpc: 14)],
                graceNotesBefore: [grace(62, tpc: 16), grace(64, tpc: 18)], graceNotesAfter: [],
            )),
            .chord(Chord(
                duration: .quarter, notes: [Note(pitch: 62, tpc: 16)],
                graceNotesBefore: [], graceNotesAfter: [grace(65, tpc: 13, type: .grace8after)],
            )),
            .rest(duration: .half),
        ])
    }

    /// The same bar on two staves of one part, so hiding staff 0 renumbers staff 1.
    private static func twoStaffScore() -> Score {
        Score(division: 480, parts: [Part(
            id: "1", instrument: Instrument(id: "x"),
            staves: [Staff(measures: [Measure(voices: [voice()])]), Staff(measures: [Measure(voices: [voice()])])],
        )])
    }

    private static func parent(_ staff: StaffAddress, element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    private static let secondBefore = GraceNoteID(
        parent: parent(staff0, element: 1), side: .before, graceIndex: 1, noteIndexInGraceChord: 0,
    )
    private static let firstAfter = GraceNoteID(
        parent: parent(staff0, element: 2), side: .after, graceIndex: 0, noteIndexInGraceChord: 0,
    )

    // MARK: - Identity

    @Test("Positional accessors answer from the owning chord's slot")
    func accessorsFollowParent() {
        let id = GraceNoteID(
            parent: VoiceElementID(staff: Self.staff1, measureIndex: 3, voiceIndex: 2, elementIndex: 5),
            side: .after, graceIndex: 1, noteIndexInGraceChord: 0,
        )
        let item = ScoreItemID.graceNote(id)
        #expect(item.staff == Self.staff1)
        #expect(item.measureIndex == 3)
        #expect(item.voiceIndex == 2)
        #expect(item.elementIndex == 5)
        #expect(item.graceNoteID == id)
        #expect(item.textID == nil)
        #expect(item.elementID == nil)
    }

    @Test("The score subscript returns the grace note itself, never the parent's")
    func subscriptResolvesGraceNote() {
        let score = Self.twoStaffScore()
        #expect(score[Self.secondBefore]?.pitch == 64)
        #expect(score[Self.firstAfter]?.pitch == 65)
        // Stale or foreign positions resolve to nothing rather than falling back to the parent chord.
        let pastEnd = GraceNoteID(
            parent: Self.parent(Self.staff0, element: 1), side: .before, graceIndex: 2, noteIndexInGraceChord: 0,
        )
        let wrongSide = GraceNoteID(
            parent: Self.parent(Self.staff0, element: 1), side: .after, graceIndex: 0, noteIndexInGraceChord: 0,
        )
        let onRest = GraceNoteID(
            parent: Self.parent(Self.staff0, element: 3), side: .before, graceIndex: 0, noteIndexInGraceChord: 0,
        )
        let noteOutOfRange = GraceNoteID(
            parent: Self.parent(Self.staff0, element: 1), side: .before, graceIndex: 0, noteIndexInGraceChord: 1,
        )
        #expect(score[pastEnd] == nil)
        #expect(score[wrongSide] == nil)
        #expect(score[onRest] == nil)
        #expect(score[noteOutOfRange] == nil)
    }

    @Test("A grace note's EID round-trips to its position")
    func eidRoundTrip() throws {
        var score = Self.twoStaffScore()
        var ids = EIDAllocator(actor: 7)
        score.assignMissingIDs(using: &ids)
        for id in [Self.secondBefore, Self.firstAfter] {
            let eid = try #require(score.eid(at: id))
            #expect(score.graceNotePosition(of: eid) == id)
            // The top-level note lookup keeps declining grace identifiers.
            #expect(score.notePosition(of: eid) == nil)
        }
        let parentNote = try #require(score.eid(at: NoteID(
            staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
        )))
        #expect(score.graceNotePosition(of: parentNote) == nil)
    }

    @Test("Mapping voice slots moves a grace identity with its parent")
    func mappingFollowsParent() {
        let moved = ScoreItemID.graceNote(Self.firstAfter).mappingVoiceElements { location in
            VoiceElementID(
                staff: location.staff, measureIndex: location.measureIndex,
                voiceIndex: location.voiceIndex, elementIndex: location.elementIndex + 4,
            )
        }
        #expect(moved == .graceNote(Self.firstAfter.withParent(Self.parent(Self.staff0, element: 6))))
        #expect(ScoreItemID.graceNote(Self.firstAfter).mappingVoiceElements { _ in nil } == nil)
    }

    // MARK: - Filtered staves

    @Test("A tap on a filtered layout re-stamps the grace note's parent onto the full-score staff, and back")
    func filteredStaffRestamp() {
        let score = Self.twoStaffScore()
        let hidden: Set<StaffAddress> = [Self.staff0]
        let displayed = ScoreItemID.graceNote(Self.secondBefore)
        let full = ScoreItemID.graceNote(Self.secondBefore.withParent(Self.parent(Self.staff1, element: 1)))

        #expect(score.engineCursorForFilteredTap(.item(displayed), hiddenStaves: hidden) == .item(full))
        #expect(score.translateCursorForHiddenStaves(.item(full), hiddenStaves: hidden) == .item(displayed))

        let map = ScoreEditingAddressMap(score: score, hiddenStaves: hidden)
        #expect(map.fullItem(forDisplayed: displayed) == full)
        #expect(map.displayedItem(forFull: full) == displayed)
        // The re-stamped identity still names the same grace note in the full score.
        #expect(full.graceNoteID.flatMap { score[$0] }?.pitch == 64)
    }

    @Test("A grace note on a hidden staff falls back to its parent's beat")
    func hiddenStaffFallsBackToBeat() {
        let score = Self.twoStaffScore()
        let onHidden = ScoreItemID.graceNote(Self.firstAfter)
        #expect(
            score.translateCursorForHiddenStaves(.item(onHidden), hiddenStaves: [Self.staff0])
                == .beat(measureIndex: 0, tickInMeasure: 480),
        )
    }

    // MARK: - Wire

    @Test("Both sides survive the wire, alone and in an array")
    func wireRoundTrip() throws {
        let items: [ScoreItemID] = [
            .graceNote(Self.secondBefore),
            .graceNote(GraceNoteID(
                parent: VoiceElementID(staff: Self.staff1, measureIndex: 12, voiceIndex: 3, elementIndex: 9),
                side: .after, graceIndex: 2, noteIndexInGraceChord: 1,
            )),
        ]
        for item in items {
            #expect(try ScoreItemIDCodec.decode(ScoreItemIDCodec.encode(item)) == item)
        }
        #expect(try ScoreItemIDCodec.decodeArray(ScoreItemIDCodec.encodeArray(items)) == items)
    }

    @Test("The grace case is wire choice 6, appended after the six existing choices")
    func wireChoiceIndex() {
        // The payload is varint(length) + varint(choice) + …, so byte 1 is the choice number itself.
        #expect(Array(ScoreItemIDCodec.encode(.graceNote(Self.firstAfter)))[1] == 6)
        let element = ScoreItemID.element(.barLine(measureIndex: 0, role: .trailing))
        #expect(Array(ScoreItemIDCodec.encode(element))[1] == 5)
    }

    // MARK: - Selection

    @Test("A grace selection covers only the grace note, and a note selection none of its graces")
    func selectionExpansionIsDisjoint() {
        let score = Self.twoStaffScore()
        let grace = ScoreItemID.graceNote(Self.firstAfter)
        let parentNote = ScoreItemID.note(NoteID(
            staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 2, noteIndexInChord: 0,
        ))
        #expect(SelectionExpansion.selectedIDs(for: .single(grace), in: score) == [grace])
        #expect(SelectionExpansion.selectedIDs(for: .single(parentNote), in: score) == [parentNote])
    }

    /// A range edit carries the graces (a transposition moves them), so a range lights them too — both sides, and
    /// only for the chords inside it.
    @Test("A range covers the grace notes of every chord in it")
    func rangeCoversItsGraces() {
        let score = Self.twoStaffScore()
        func note(_ element: Int) -> ScoreItemID {
            .note(NoteID(
                staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: element, noteIndexInChord: 0,
            ))
        }
        let firstBefore = GraceNoteID(
            parent: Self.parent(Self.staff0, element: 1), side: .before, graceIndex: 0, noteIndexInGraceChord: 0,
        )

        let both = SelectionExpansion.selectedIDs(for: .range(anchor: note(1), target: note(2)), in: score)
        #expect(both == [
            note(1), note(2), .graceNote(firstBefore), .graceNote(Self.secondBefore), .graceNote(Self.firstAfter),
        ])

        let first = SelectionExpansion.selectedIDs(for: .range(anchor: note(1), target: note(1)), in: score)
        #expect(first == [note(1), .graceNote(firstBefore), .graceNote(Self.secondBefore)])
    }
}
