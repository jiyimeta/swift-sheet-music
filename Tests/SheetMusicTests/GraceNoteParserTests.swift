@testable import SheetMusicCore
import Testing

@Suite("GraceType")
struct GraceTypeTests {
    @Test("isAfter is true exactly for the 3 *after tags")
    func isAfterFlag() {
        #expect(GraceType.acciaccatura.isAfter == false)
        #expect(GraceType.appoggiatura.isAfter == false)
        #expect(GraceType.grace4.isAfter == false)
        #expect(GraceType.grace16.isAfter == false)
        #expect(GraceType.grace32.isAfter == false)
        #expect(GraceType.grace8after.isAfter == true)
        #expect(GraceType.grace16after.isAfter == true)
        #expect(GraceType.grace32after.isAfter == true)
    }

    @Test("mscxTag round-trips every case")
    func mscxTagRoundTrip() {
        let all: [GraceType] = [
            .acciaccatura, .appoggiatura,
            .grace4, .grace16, .grace32,
            .grace8after, .grace16after, .grace32after,
        ]
        for g in all {
            #expect(GraceType(mscxTag: g.mscxTag) == g)
        }
        #expect(GraceType(mscxTag: "Note") == nil)
    }
}

@Suite("GraceChord")
struct GraceChordTests {
    @Test("Stores graceType, duration, notes; Equatable")
    func basics() {
        let n = Note(pitch: 60, tpc: 14)
        let g = GraceChord(
            graceType: .acciaccatura,
            duration: .eighth,
            notes: ChordNotes([n])
        )
        #expect(g.graceType == .acciaccatura)
        #expect(g.duration == .eighth)
        #expect(g.notes.count == 1)
        #expect(g == GraceChord(
            graceType: .acciaccatura,
            duration: .eighth,
            notes: ChordNotes([n])
        ))
    }
}

@Suite("Chord with graces")
struct ChordWithGracesTests {
    @Test("Default init leaves grace arrays empty (source compat)")
    func defaultsEmpty() {
        let c = Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))
        #expect(c.graceNotesBefore.isEmpty)
        #expect(c.graceNotesAfter.isEmpty)
    }

    @Test("graceNotesBefore / After are stored and Equatable")
    func storesGraces() {
        let g = GraceChord(
            graceType: .acciaccatura, duration: .eighth,
            notes: ChordNotes([Note(pitch: 62, tpc: 16)])
        )
        let c = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            graceNotesBefore: [g],
            graceNotesAfter: []
        )
        #expect(c.graceNotesBefore == [g])
        #expect(c.graceNotesAfter.isEmpty)
    }
}
