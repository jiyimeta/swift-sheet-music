@testable import SheetMusicCore
import Testing

/// `ElementNavigator.nextChordRest` / `previousChordRest`: MuseScore's plain-arrow walk, which stops on grace notes.
@Suite("ElementNavigator — chord/rest walk with grace notes")
struct ElementNavigatorGraceTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func grace(_ pitch: Int, _ type: GraceType = .acciaccatura) -> GraceChord {
        GraceChord(graceType: type, duration: .eighth, notes: [Note(pitch: pitch, tpc: 14)])
    }

    private static func score(_ measures: [[VoiceElement]]) -> Score {
        Score(division: 480, parts: [Part(
            id: "1", instrument: Instrument(id: "x"),
            staves: [Staff(measures: measures.map { Measure(voices: [Voice(elements: $0)]) })],
        )])
    }

    /// `[clef, q C(before: g1, g2), q D(after: g3)] | [q E]`.
    private static func graceScore() -> Score {
        score([
            [
                .clef(Clef(concertClefType: "G")),
                .chord(Chord(
                    duration: .quarter, notes: [Note(pitch: 60, tpc: 14)],
                    graceNotesBefore: [grace(62), grace(64)], graceNotesAfter: [],
                )),
                .chord(Chord(
                    duration: .quarter, notes: [Note(pitch: 62, tpc: 16)],
                    graceNotesBefore: [], graceNotesAfter: [grace(65, .grace8after)],
                )),
            ],
            [.chord(Chord(duration: .quarter, notes: [Note(pitch: 64, tpc: 18)]))],
        ])
    }

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff0, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func note(_ measure: Int, _ element: Int, _ index: Int = 0) -> ScoreItemID {
        .note(NoteID(
            staff: staff0, measureIndex: measure, voiceIndex: 0, elementIndex: element, noteIndexInChord: index,
        ))
    }

    private static func graceNote(
        _ measure: Int, _ element: Int, _ side: GraceNoteID.Side, _ index: Int,
    ) -> ScoreItemID {
        .graceNote(GraceNoteID(parent: slot(measure, element), side: side, graceIndex: index, noteIndexInGraceChord: 0))
    }

    private static let g1 = graceNote(0, 1, .before, 0)
    private static let g2 = graceNote(0, 1, .before, 1)
    private static let chordC = note(0, 1)
    private static let chordD = note(0, 2)
    private static let g3 = graceNote(0, 2, .after, 0)
    private static let chordE = note(1, 0)

    /// Every item the walk visits from `start`, `start` included, until it returns `nil`. Capped so a cycle fails
    /// the expectation instead of hanging the run.
    private static func walk(
        from start: ScoreItemID, in score: Score, _ step: (ScoreItemID, Score) -> ScoreItemID?,
    ) -> [ScoreItemID] {
        var visited = [start]
        while visited.count < 32, let next = step(visited[visited.count - 1], score) {
            visited.append(next)
        }
        return visited
    }

    @Test("Forward: before-graces, their chord, the next chord, its after-grace, then across the barline")
    func forwardOrder() {
        let visited = Self.walk(from: Self.g1, in: Self.graceScore()) {
            ElementNavigator.nextChordRest(after: $0, in: $1)
        }
        #expect(visited == [Self.g1, Self.g2, Self.chordC, Self.chordD, Self.g3, Self.chordE])
    }

    @Test("Backward is the exact reverse")
    func backwardOrder() {
        let visited = Self.walk(from: Self.chordE, in: Self.graceScore()) {
            ElementNavigator.previousChordRest(before: $0, in: $1)
        }
        #expect(visited == [Self.chordE, Self.g3, Self.chordD, Self.chordC, Self.g2, Self.g1])
    }

    @Test("Each single step agrees with the walk from both of its ends")
    func stepsAreInverse() {
        let score = Self.graceScore()
        let order = [Self.g1, Self.g2, Self.chordC, Self.chordD, Self.g3, Self.chordE]
        for (from, to) in zip(order, order.dropFirst()) {
            #expect(ElementNavigator.nextChordRest(after: from, in: score) == to)
            #expect(ElementNavigator.previousChordRest(before: to, in: score) == from)
        }
    }

    @Test("A stale grace identity, or an item that is not a chord, rest or grace note, has no neighbour")
    func staleAndForeignItems() {
        let score = Self.graceScore()
        let stale = Self.graceNote(0, 1, .before, 2)
        let onChordWithoutAfterGraces = Self.graceNote(0, 1, .after, 0)
        for item in [stale, onChordWithoutAfterGraces, ScoreItemID.clef(.staffDefault(Self.staff0))] {
            #expect(ElementNavigator.nextChordRest(after: item, in: score) == nil)
            #expect(ElementNavigator.previousChordRest(before: item, in: score) == nil)
        }
    }

    @Test("Stepping onto a chord lands on its note 0; a rest owns no graces")
    func landingConventions() {
        let score = Self.score([[
            .chord(Chord(
                duration: .quarter, notes: [Note(pitch: 60, tpc: 14), Note(pitch: 67, tpc: 15)],
                graceNotesBefore: [], graceNotesAfter: [Self.grace(62, .grace8after)],
            )),
            .rest(duration: .quarter),
            .chord(Chord(
                duration: .quarter, notes: [Note(pitch: 64, tpc: 18), Note(pitch: 72, tpc: 14)],
                graceNotesBefore: [Self.grace(65)], graceNotesAfter: [],
            )),
        ]])
        let after = Self.graceNote(0, 0, .after, 0)
        let rest = ScoreItemID.rest(RestID(staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1))
        let before = Self.graceNote(0, 2, .before, 0)
        // From the upper note of the first chord, too: which note is selected does not change the walk.
        #expect(ElementNavigator.nextChordRest(after: Self.note(0, 0, 1), in: score) == after)
        #expect(ElementNavigator.nextChordRest(after: after, in: score) == rest)
        #expect(ElementNavigator.nextChordRest(after: rest, in: score) == before)
        #expect(ElementNavigator.nextChordRest(after: before, in: score) == Self.note(0, 2))
        #expect(ElementNavigator.previousChordRest(before: before, in: score) == rest)
        #expect(ElementNavigator.previousChordRest(before: rest, in: score) == after)
        #expect(ElementNavigator.previousChordRest(before: after, in: score) == Self.note(0, 0))
    }

    @Test("Without graces the walk visits exactly the slots nextTimedElement / previousTimedElement do")
    func matchesTimedWalkWithoutGraces() {
        let score = Self.score([
            [
                .clef(Clef(concertClefType: "G")),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                .rest(duration: .quarter),
            ],
            [.rest(duration: .measure), .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)]))],
        ])
        let forward = Self.walk(from: Self.note(0, 1), in: score) {
            ElementNavigator.nextChordRest(after: $0, in: $1)
        }
        var slots = [Self.slot(0, 1)]
        while let next = ElementNavigator.nextTimedElement(after: slots[slots.count - 1], in: score) {
            slots.append(next)
        }
        #expect(forward.map { VoiceElementID($0) } == slots)
        #expect(forward.count == 4)
        let backward = Self.walk(from: forward[forward.count - 1], in: score) {
            ElementNavigator.previousChordRest(before: $0, in: $1)
        }
        #expect(backward == forward.reversed())
    }
}
