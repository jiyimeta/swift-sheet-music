import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Pins the main-note side of a grace tie: `Chord.graceBeforeTieBackLocations()`
/// and its wiring into `Chord.encodeAsChord`. Verified against MuseScore Studio's
/// own source — see `Chord.graceBeforeTieBackLocations()`'s doc comment for the
/// citation trail.
///
/// The regression tests here matter more than the positive ones: this path
/// runs for *every* tied chord in *every* score, grace or not, so a mistake
/// here has a far larger blast radius than the grace-tie bug it fixes.
@Suite("Grace note encoding — main note's tie side")
struct GraceTieMainNoteEncoderTests {
    /// Locate the `<Spanner type="Tie">`'s `<prev>` (or nil) on the first
    /// `<Note>` of the given `<Chord>` node.
    private func tieBackPrev(of chordNode: XMLTreeNode) -> XMLTreeNode? {
        chordNode.first("Note")?
            .all("Spanner")
            .first { $0.attributes["type"] == "Tie" }?
            .first("prev")
    }

    /// Direct-child presence check, without going through `first(_:)`
    /// (whose `== nil` shape at the call site reads to SwiftLint as
    /// `first(where:) != nil` and asks for `contains` instead).
    private func hasChild(_ name: String, in node: XMLTreeNode) -> Bool {
        node.children.contains { $0.name == name }
    }

    // MARK: - Regression: chords untouched by this fix must be byte-identical

    /// An ordinary tie with no grace notes anywhere in the voice must keep
    /// using `Voice.backwardTieLocation`'s chord-to-chord computation —
    /// `<fractions>`, no `<grace>`.
    @Test("An ordinary tie (no grace notes at all) is unaffected")
    func ordinaryTieUnaffectedByGraceCode() throws {
        let voice = Voice(elements: [
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14, tieForward: 1)]),
            )),
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14, tieBack: 1)]),
            )),
        ])
        let chordNodes = try voice.encode().all("Chord")
        #expect(chordNodes.count == 2)
        guard chordNodes.count == 2 else { return }

        let prev = try #require(tieBackPrev(of: chordNodes[1]))
        let location = try #require(prev.first("location"))
        #expect(!hasChild("grace", in: location))
        #expect(location.first("fractions")?.text == "-1/4")
    }

    /// A chord with `graceNotesBefore` whose graces carry no tie at all must
    /// still take the ordinary location — the override map is empty, so
    /// output is unchanged from before this fix.
    @Test("A chord with grace notes but no grace-side tie is unaffected")
    func graceNotesPresentButUntiedLeavesOrdinaryLocation() throws {
        let decorativeGrace = GraceChord(
            graceType: .acciaccatura,
            duration: .sixteenth,
            notes: ChordNotes([Note(pitch: 62, tpc: 16)]), // no tieForward
        )
        let voice = Voice(elements: [
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14, tieForward: 1)]),
            )),
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14, tieBack: 1)]),
                graceNotesBefore: [decorativeGrace],
            )),
        ])
        let chordNodes = try voice.encode().all("Chord")
        // 3 <Chord> nodes: the decorative grace sibling, then the two main chords.
        #expect(chordNodes.count == 3)
        guard chordNodes.count == 3 else { return }

        let mainSecond = chordNodes[2]
        #expect(mainSecond.all("Note").map { $0.first("pitch")?.text } == ["60"])
        let prev = try #require(tieBackPrev(of: mainSecond))
        let location = try #require(prev.first("location"))
        #expect(!hasChild("grace", in: location))
        #expect(location.first("fractions")?.text == "-1/4")
    }

    // MARK: - Positive: an unambiguous grace-before / tieForward partner

    /// The primary figure this fix targets: a tied acciaccatura into its
    /// own main note. The main chord is first in the voice (no previous
    /// chord, so `Voice.backwardTieLocation` alone would yield `nil` and
    /// the note would encode a bare, tie-losing `<prev/>`, exactly the bug
    /// this task closes). With the override, `<prev>` carries
    /// `<location><grace>0</grace></location>` — no `<fractions>`.
    @Test("A main note's tieBack matching a graceNotesBefore note's tieForward uses <grace>")
    func graceBeforeTieBackUsesGraceIndex() throws {
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
        #expect(chordNodes.count == 2) // grace sibling + main chord
        guard chordNodes.count == 2 else { return }

        let prev = try #require(tieBackPrev(of: chordNodes[1]))
        #expect(prev.children.count == 1)
        let location = try #require(prev.first("location"))
        #expect(location.children.count == 1)
        #expect(location.first("grace")?.text == "0")
        #expect(!hasChild("fractions", in: location))
    }

    /// The grace's position among `graceNotesBefore` — not its pitch or
    /// array insertion order alone — is what becomes `<grace>N</grace>`.
    /// A second, untied grace ahead of the tied one shifts the index to 1.
    @Test("The <grace> index reflects the tied grace's position among graceNotesBefore")
    func graceIndexReflectsPositionAmongGraces() throws {
        let untied = GraceChord(
            graceType: .grace16,
            duration: .sixteenth,
            notes: ChordNotes([Note(pitch: 64, tpc: 18)]),
        )
        let tied = GraceChord(
            graceType: .grace16,
            duration: .sixteenth,
            notes: ChordNotes([Note(pitch: 60, tpc: 14, tieForward: 1)]),
        )
        let voice = Voice(elements: [
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14, tieBack: 1)]),
                graceNotesBefore: [untied, tied],
            )),
        ])
        let chordNodes = try voice.encode().all("Chord")
        #expect(chordNodes.count == 3) // 2 grace siblings + main chord
        guard chordNodes.count == 3 else { return }

        let prev = try #require(tieBackPrev(of: chordNodes[2]))
        let location = try #require(prev.first("location"))
        #expect(location.first("grace")?.text == "1")
    }

    // MARK: - Ambiguity: prefer the ordinary location over a guess

    /// Two graces at the same pitch, both tied forward: the encoder can't
    /// tell which one is the real partner, so it must leave the ordinary
    /// (here: nil, since this is the first chord in the voice) location
    /// rather than guessing — a bare `<prev/>`, same as before this fix.
    @Test("Two grace notes at the same tied pitch fall back to the ordinary location")
    func ambiguousGracePitchLeavesOrdinaryLocation() throws {
        let grace1 = GraceChord(
            graceType: .acciaccatura,
            duration: .sixteenth,
            notes: ChordNotes([Note(pitch: 60, tpc: 14, tieForward: 1)]),
        )
        let grace2 = GraceChord(
            graceType: .acciaccatura,
            duration: .sixteenth,
            notes: ChordNotes([Note(pitch: 60, tpc: 14, tieForward: 1)]),
        )
        let voice = Voice(elements: [
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14, tieBack: 1)]),
                graceNotesBefore: [grace1, grace2],
            )),
        ])
        let chordNodes = try voice.encode().all("Chord")
        #expect(chordNodes.count == 3)
        guard chordNodes.count == 3 else { return }

        let mainChord = chordNodes[2]
        let spanner = mainChord.first("Note")?.all("Spanner")
            .first { $0.attributes["type"] == "Tie" }
        let prev = try #require(spanner?.first("prev"))
        // No previous real chord and an ambiguous grace match: today's
        // (pre-fix) shape — a location-less <prev/>.
        #expect(prev.children.isEmpty)
    }

    // MARK: - Multi-note chord: only the matching note gets the override

    /// A two-note chord where one note ties to a grace and the other ties
    /// ordinarily to the previous real chord: only the matching note's
    /// `<prev>` gets `<grace>`; the other keeps the chord-to-chord fraction.
    @Test("Only the note that matches a grace gets the <grace> override; its chord-mate does not")
    func onlyMatchingNoteInMultiNoteChordGetsOverride() throws {
        let grace = GraceChord(
            graceType: .acciaccatura,
            duration: .sixteenth,
            notes: ChordNotes([Note(pitch: 60, tpc: 14, tieForward: 1)]),
        )
        let voice = Voice(elements: [
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 64, tpc: 18, tieForward: 1)]),
            )),
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([
                    Note(pitch: 60, tpc: 14, tieBack: 1), // ties to the grace
                    Note(pitch: 64, tpc: 18, tieBack: 1), // ties to the previous real chord
                ]),
                graceNotesBefore: [grace],
            )),
        ])
        let chordNodes = try voice.encode().all("Chord")
        #expect(chordNodes.count == 3) // grace sibling + 2 main chords
        guard chordNodes.count == 3 else { return }

        let mainSecond = chordNodes[2]
        let noteNodes = mainSecond.all("Note")
        #expect(noteNodes.count == 2)
        guard noteNodes.count == 2 else { return }

        func prev(of noteNode: XMLTreeNode) -> XMLTreeNode? {
            noteNode.all("Spanner").first { $0.attributes["type"] == "Tie" }?.first("prev")
        }

        let gracePartnerPrev = try #require(prev(of: noteNodes[0]))
        let graceLocation = try #require(gracePartnerPrev.first("location"))
        #expect(graceLocation.first("grace")?.text == "0")
        #expect(!hasChild("fractions", in: graceLocation))

        let ordinaryPartnerPrev = try #require(prev(of: noteNodes[1]))
        let ordinaryLocation = try #require(ordinaryPartnerPrev.first("location"))
        #expect(!hasChild("grace", in: ordinaryLocation))
        #expect(ordinaryLocation.first("fractions")?.text == "-1/4")
    }
}
