import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// `<notes>` on an ordinary chord-to-chord tie.
///
/// MuseScore's endpoint match compares full `Location` equality
/// including `m_note`, which `Location::toRelative` carries as a delta
/// between the two endpoints' own note indices. Two chords of different
/// shapes give the same pitch different indices, so a tie between them
/// needs a non-zero `<notes>` on both sides or MuseScore drops it on
/// reload — a failure this project's own round trip cannot observe,
/// since its decoder never reads `<location>` content at all.
@Suite("Ordinary tie — <notes> index")
struct OrdinaryTieNotesIndexTests {
    private func tieSide(_ side: String, of noteNode: XMLTreeNode) -> XMLTreeNode? {
        noteNode.all("Spanner")
            .first { $0.attributes["type"] == "Tie" }?
            .first(side)
    }

    private func location(
        _ side: String, ofPitch pitch: Int, in chordNode: XMLTreeNode,
    ) throws -> XMLTreeNode {
        let note = try #require(
            chordNode.all("Note").first { $0.first("pitch")?.text == String(pitch) },
        )
        return try #require(tieSide(side, of: note)?.first("location"))
    }

    private func hasChild(_ name: String, in node: XMLTreeNode) -> Bool {
        node.children.contains { $0.name == name }
    }

    /// A two-note chord tied into a single-note chord. The tied pitch
    /// ranks second in the first chord and — being alone — index `0` in
    /// the second, so the deltas are `-1` going forward and `+1` coming
    /// back. Both chords are written with their notes in descending
    /// pitch order, since `Location::note` ranks by pitch and not by
    /// the order the `<Note>` elements appear in.
    @Test("A tie between chords of different shapes carries <notes> on both sides")
    func differentShapedChordsCarryNotesDelta() throws {
        let voice = Voice(elements: [
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([
                    Note(pitch: 64, tpc: 18, tieForward: 1),
                    Note(pitch: 60, tpc: 14),
                ]),
            )),
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 64, tpc: 18, tieBack: 1)]),
            )),
        ])
        let chordNodes = try voice.encode().all("Chord")
        #expect(chordNodes.count == 2)
        guard chordNodes.count == 2 else { return }

        let next = try location("next", ofPitch: 64, in: chordNodes[0])
        #expect(next.first("fractions")?.text == "1/4")
        #expect(next.first("notes")?.text == "-1")

        let prev = try location("prev", ofPitch: 64, in: chordNodes[1])
        #expect(prev.first("fractions")?.text == "-1/4")
        #expect(prev.first("notes")?.text == "1")
    }

    /// The overwhelmingly common case — chords that give the tied pitch
    /// the same rank — keeps emitting no `<notes>` at all, so every
    /// existing file this encoder produces is unchanged.
    @Test("A tie between same-shaped chords emits no <notes>")
    func sameShapedChordsEmitNoNotes() throws {
        let voice = Voice(elements: [
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([
                    Note(pitch: 60, tpc: 14),
                    Note(pitch: 64, tpc: 18, tieForward: 1),
                ]),
            )),
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([
                    Note(pitch: 60, tpc: 14),
                    Note(pitch: 64, tpc: 18, tieBack: 1),
                ]),
            )),
        ])
        let chordNodes = try voice.encode().all("Chord")
        guard chordNodes.count == 2 else { Issue.record("shape"); return }

        #expect(try !hasChild("notes", in: location("next", ofPitch: 64, in: chordNodes[0])))
        #expect(try !hasChild("notes", in: location("prev", ofPitch: 64, in: chordNodes[1])))
    }

    /// The same tie across a bar line. The forward side needs the *next
    /// measure's* first chord, which the measure-at-a-time encoder has
    /// no view of on its own — `Staff.encodeTopLevel` supplies it as a
    /// one-measure look-ahead. Without that the forward side would fall
    /// back to `0` while the backward side (which rides the existing
    /// carry) emitted `1`, and the two would never match.
    @Test("A cross-measure tie between different shapes carries <notes> on both sides")
    func crossMeasureCarriesNotesDelta() throws {
        let staff = Staff(
            staffType: "stdNormal",
            group: "pitched",
            defaultClefType: nil,
            measures: [
                Measure(voices: [Voice(elements: [
                    .chord(Chord(
                        duration: .whole,
                        notes: ChordNotes([
                            Note(pitch: 64, tpc: 18, tieForward: 1),
                            Note(pitch: 60, tpc: 14),
                        ]),
                    )),
                ])]),
                Measure(voices: [Voice(elements: [
                    .chord(Chord(
                        duration: .whole,
                        notes: ChordNotes([Note(pitch: 64, tpc: 18, tieBack: 1)]),
                    )),
                ])]),
            ],
        )
        let measureNodes = try staff.encodeTopLevel(staffID: "1").all("Measure")
        #expect(measureNodes.count == 2)
        guard measureNodes.count == 2 else { return }

        let first = try #require(measureNodes[0].first("voice")?.first("Chord"))
        let next = try location("next", ofPitch: 64, in: first)
        #expect(next.first("measures")?.text == "1")
        #expect(next.first("notes")?.text == "-1")

        let second = try #require(measureNodes[1].first("voice")?.first("Chord"))
        let prev = try location("prev", ofPitch: 64, in: second)
        #expect(prev.first("measures")?.text == "-1")
        #expect(prev.first("notes")?.text == "1")
    }
}
