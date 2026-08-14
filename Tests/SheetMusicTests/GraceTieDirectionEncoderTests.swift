import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Which chord each side of a grace tie points at, and which note of
/// that chord.
///
/// A grace shares its parent chord's tick, so "zero delta, same
/// measure" is right only for the tie direction that stays inside the
/// parent; the other direction leaves it and needs the parent's own
/// neighbour-chord delta. Sounding order decides which is which, and
/// that is fixed by the grace type — see `GraceChord.encode`'s doc
/// comment for the table and its citation trail.
@Suite("Grace tie direction and note index")
struct GraceTieDirectionEncoderTests {
    private func tieSide(_ side: String, of noteNode: XMLTreeNode) -> XMLTreeNode? {
        noteNode.all("Spanner")
            .first { $0.attributes["type"] == "Tie" }?
            .first(side)
    }

    private func hasChild(_ name: String, in node: XMLTreeNode) -> Bool {
        node.children.contains { $0.name == name }
    }

    private func quarter(_ pitch: Int, tpc: Int) -> Chord {
        Chord(duration: .quarter, notes: ChordNotes([Note(pitch: pitch, tpc: tpc)]))
    }

    // MARK: - Tied Nachschlag: main note ties forward into its own after-grace

    /// The mirror of the tied-acciaccatura figure. Both sides are
    /// zero-delta (the after-grace shares its parent's tick), and the
    /// main note's `<next>` names the grace by ordinal because the
    /// partner *is* a grace. Without the override the main note would
    /// carry the ordinary chord-to-chord location — here `nil`, i.e. a
    /// tie-losing bare `<next/>` — so this test fails on the pre-fix
    /// encoder.
    @Test("A main note's tieForward matching a graceNotesAfter note's tieBack uses <grace>")
    func graceAfterTieForwardUsesGraceIndex() throws {
        let grace = GraceChord(
            graceType: .grace8after,
            duration: .eighth,
            notes: ChordNotes([Note(pitch: 60, tpc: 14, tieBack: 1)]),
        )
        let voice = Voice(elements: [
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14, tieForward: 1)]),
                graceNotesAfter: [grace],
            )),
        ])
        let chordNodes = try voice.encode().all("Chord")
        #expect(chordNodes.count == 2) // grace sibling (ahead) + main chord
        guard chordNodes.count == 2 else { return }

        // Main note's <next>: <location><grace>0</grace></location>.
        let mainNote = try #require(chordNodes[1].first("Note"))
        let next = try #require(tieSide("next", of: mainNote))
        let location = try #require(next.first("location"))
        #expect(location.first("grace")?.text == "0")
        #expect(!hasChild("fractions", in: location))

        // The grace's own <prev> is the zero-delta empty location: its
        // partner is an ordinary note, so no <grace> is needed.
        let graceNote = try #require(chordNodes[0].first("Note"))
        let prev = try #require(tieSide("prev", of: graceNote))
        let graceLocation = try #require(prev.first("location"))
        #expect(graceLocation.children.isEmpty)
    }

    /// The `<grace>` ordinal is the partner's position in the combined
    /// file run, which is `graceNotesBefore` forward followed by
    /// `graceNotesAfter` reversed (`Chord.mscxFileOrderedGraces`). With
    /// two of each, `graceNotesAfter[0]` is written third and last,
    /// so its ordinal is 3 — not 0, and not 2.
    @Test("Grace ordinals count across the whole combined run")
    func graceOrdinalsSpanTheCombinedRun() throws {
        func grace(_ type: GraceType, _ pitch: Int, tpc: Int, note: Note) -> GraceChord {
            GraceChord(graceType: type, duration: .sixteenth, notes: ChordNotes([note]))
        }
        let before0 = grace(.grace16, 64, tpc: 18, note: Note(pitch: 64, tpc: 18))
        let before1 = grace(
            .grace16, 60, tpc: 14, note: Note(pitch: 60, tpc: 14, tieForward: 1),
        )
        let after0 = grace(
            .grace16after, 62, tpc: 16, note: Note(pitch: 62, tpc: 16, tieBack: 1),
        )
        let after1 = grace(.grace16after, 65, tpc: 13, note: Note(pitch: 65, tpc: 13))
        let voice = Voice(elements: [
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([
                    Note(pitch: 60, tpc: 14, tieBack: 1),
                    Note(pitch: 62, tpc: 16, tieForward: 1),
                ]),
                graceNotesBefore: [before0, before1],
                graceNotesAfter: [after0, after1],
            )),
        ])
        let chordNodes = try voice.encode().all("Chord")
        #expect(chordNodes.count == 5) // 4 grace siblings + main chord
        guard chordNodes.count == 5 else { return }

        // File order: before0, before1, after1, after0, main.
        #expect(
            chordNodes.map { $0.first("Note")?.first("pitch")?.text }
                == ["64", "60", "65", "62", "60"],
        )

        let mainNotes = chordNodes[4].all("Note")
        #expect(mainNotes.count == 2)
        guard mainNotes.count == 2 else { return }

        // pitch 60 ties back to before1 → ordinal 1.
        let prev = try #require(tieSide("prev", of: mainNotes[0]))
        #expect(try #require(prev.first("location")).first("grace")?.text == "1")

        // pitch 62 ties forward to after0, which is written last → ordinal 3.
        let next = try #require(tieSide("next", of: mainNotes[1]))
        #expect(try #require(next.first("location")).first("grace")?.text == "3")
    }

    // MARK: - <notes>: which note of the chord each side refers to

    /// `<notes>` is `Location::note(partner) − Location::note(self)`,
    /// and `Location::note` ranks the note **by pitch** within its
    /// chord, not by the order the `<Note>` elements appear in. The main
    /// chord here is built with its notes in descending pitch order to
    /// separate the two: pitch 64 is written first but ranks second.
    /// Both sides must agree, or MuseScore's endpoint comparison fails
    /// and drops the tie.
    @Test("<notes> carries the by-pitch index delta on both sides of a grace tie")
    func notesDeltaOnBothSides() throws {
        let grace = GraceChord(
            graceType: .acciaccatura,
            duration: .sixteenth,
            notes: ChordNotes([Note(pitch: 64, tpc: 18, tieForward: 1)]),
        )
        let voice = Voice(elements: [
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([
                    Note(pitch: 64, tpc: 18, tieBack: 1), // rank 1 by pitch
                    Note(pitch: 60, tpc: 14), // rank 0 by pitch
                ]),
                graceNotesBefore: [grace],
            )),
        ])
        let chordNodes = try voice.encode().all("Chord")
        #expect(chordNodes.count == 2)
        guard chordNodes.count == 2 else { return }

        // Grace side: partner ranks 1, self ranks 0 (alone) → +1.
        let graceNote = try #require(chordNodes[0].first("Note"))
        let next = try #require(tieSide("next", of: graceNote))
        let graceLocation = try #require(next.first("location"))
        #expect(graceLocation.first("notes")?.text == "1")

        // Main side: partner ranks 0, self ranks 1 → -1, alongside <grace>.
        let mainNote = try #require(chordNodes[1].all("Note").first)
        #expect(mainNote.first("pitch")?.text == "64")
        let prev = try #require(tieSide("prev", of: mainNote))
        let mainLocation = try #require(prev.first("location"))
        #expect(mainLocation.first("grace")?.text == "0")
        #expect(mainLocation.first("notes")?.text == "-1")
    }

    /// Both notes alone in their chords is the case that already worked
    /// before `<notes>` existed here — `Location::note` special-cases a
    /// single-note chord to `0`, so the delta is `0` and the element
    /// elides. Pins that the new field stays invisible there.
    @Test("Single-note chords on both sides emit no <notes>")
    func singleNoteChordsEmitNoNotesElement() throws {
        let grace = GraceChord(
            graceType: .acciaccatura,
            duration: .sixteenth,
            notes: ChordNotes([Note(pitch: 60, tpc: 14, tieForward: 1)]),
        )
        let voice = Voice(elements: [
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14, tieBack: 1)]),
                graceNotesBefore: [grace],
            )),
        ])
        let chordNodes = try voice.encode().all("Chord")
        guard chordNodes.count == 2 else { Issue.record("shape"); return }
        for node in chordNodes {
            for note in node.all("Note") {
                for side in ["next", "prev"] {
                    guard let location = tieSide(side, of: note)?.first("location")
                    else { continue }
                    #expect(!hasChild("notes", in: location))
                }
            }
        }
    }

    // MARK: - The tie direction that leaves the parent chord

    /// A before-grace sounds ahead of its parent, so its `tieBack` can
    /// only come from the *previous* main chord — never from the parent,
    /// which has not sounded yet. The pre-fix encoder wrote the
    /// zero-delta empty location here, naming the parent.
    @Test("A before-grace's tieBack points at the previous chord, not its parent")
    func beforeGraceTieBackPointsAtPreviousChord() throws {
        let grace = GraceChord(
            graceType: .appoggiatura,
            duration: .eighth,
            notes: ChordNotes([Note(pitch: 60, tpc: 14, tieBack: 1)]),
        )
        var second = quarter(62, tpc: 16)
        second.graceNotesBefore = [grace]
        let voice = Voice(elements: [
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14, tieForward: 1)]),
            )),
            .chord(second),
        ])
        let chordNodes = try voice.encode().all("Chord")
        #expect(chordNodes.count == 3) // chord 1, grace sibling, chord 2
        guard chordNodes.count == 3 else { return }

        let graceNote = try #require(chordNodes[1].first("Note"))
        #expect(graceNote.first("pitch")?.text == "60")
        let prev = try #require(tieSide("prev", of: graceNote))
        let location = try #require(prev.first("location"))
        #expect(location.first("fractions")?.text == "-1/4")
    }

    /// The mirror: an after-grace sounds past its parent, so its
    /// `tieForward` reaches the *next* main chord and carries that
    /// chord's delta rather than zero.
    @Test("An after-grace's tieForward points at the next chord, not its parent")
    func afterGraceTieForwardPointsAtNextChord() throws {
        let grace = GraceChord(
            graceType: .grace8after,
            duration: .eighth,
            notes: ChordNotes([Note(pitch: 62, tpc: 16, tieForward: 1)]),
        )
        var first = quarter(60, tpc: 14)
        first.graceNotesAfter = [grace]
        let voice = Voice(elements: [
            .chord(first),
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 62, tpc: 16, tieBack: 1)]),
            )),
        ])
        let chordNodes = try voice.encode().all("Chord")
        #expect(chordNodes.count == 3) // grace sibling, chord 1, chord 2
        guard chordNodes.count == 3 else { return }

        let graceNote = try #require(chordNodes[0].first("Note"))
        #expect(graceNote.first("pitch")?.text == "62")
        let next = try #require(tieSide("next", of: graceNote))
        let location = try #require(next.first("location"))
        #expect(location.first("fractions")?.text == "1/4")
    }

    /// With no previous chord to point at, no `<location>` is written —
    /// a confidently wrong one could mis-connect to whatever note sits
    /// at the named position, which is worse than the tie being dropped.
    @Test("A before-grace's tieBack with no previous chord writes no <location>")
    func beforeGraceTieBackWithoutPreviousChordWritesNoLocation() throws {
        let grace = GraceChord(
            graceType: .appoggiatura,
            duration: .eighth,
            notes: ChordNotes([Note(pitch: 60, tpc: 14, tieBack: 1)]),
        )
        var only = quarter(62, tpc: 16)
        only.graceNotesBefore = [grace]
        let voice = Voice(elements: [.chord(only)])
        let chordNodes = try voice.encode().all("Chord")
        guard chordNodes.count == 2 else { Issue.record("shape"); return }

        let graceNote = try #require(chordNodes[0].first("Note"))
        let prev = try #require(tieSide("prev", of: graceNote))
        #expect(prev.children.isEmpty)
    }
}
