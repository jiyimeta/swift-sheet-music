import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Encoder-side counterpart to `GraceNoteParserTests` — pins the wire
/// shape the encoder must produce (structural test) and confirms the
/// fix closes the parse → encode → parse data-loss bug (round-trip
/// fingerprint test).
@Suite("Grace note encoding — structural")
struct GraceNoteEncoderStructuralTests {
    /// A minimal `<voice>` with one main chord carrying a before-grace
    /// and an after-grace. Encoding it must emit three sibling
    /// `<Chord>` nodes — **both** graces ahead of the parent, the way
    /// MuseScore's writer emits `Chord::graceNotes()` — and the grace
    /// ones must carry their own grace-type tag rather than being
    /// folded into (or dropped from) the main chord's node.
    @Test("Before- and after-graces are both emitted ahead of the parent <Chord>")
    func gracesEmittedAsSiblings() throws {
        let before = GraceChord(
            graceType: .acciaccatura,
            duration: .eighth,
            notes: ChordNotes([Note(pitch: 62, tpc: 16)]),
        )
        let after = GraceChord(
            graceType: .grace8after,
            duration: .eighth,
            notes: ChordNotes([Note(pitch: 64, tpc: 18)]),
        )
        let voice = Voice(elements: [
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
                graceNotesBefore: [before],
                graceNotesAfter: [after],
            )),
        ])

        let voiceNode = try voice.encode()
        let chordNodes = voiceNode.all("Chord")

        #expect(chordNodes.count == 3)
        guard chordNodes.count == 3 else { return }

        // 1. The before-grace: its own <Chord>, tagged <acciaccatura/>,
        // carrying only its own note (pitch 62).
        #expect(chordNodes[0].hasChild("acciaccatura"))
        #expect(chordNodes[0].all("Note").map(\.pitch) == [62])

        // 2. The after-grace: also ahead of the parent, tagged
        // <grace8after/>, carrying only its own note (pitch 64).
        #expect(chordNodes[1].hasChild("grace8after"))
        #expect(chordNodes[1].all("Note").map(\.pitch) == [64])

        // 3. The main chord: no grace tag, carries the main note
        // (pitch 60) and neither grace's note.
        for graceTag in GraceType.allCases.map(\.mscxTag) {
            #expect(!chordNodes[2].hasChild(graceTag))
        }
        #expect(chordNodes[2].all("Note").map(\.pitch) == [60])
    }

    /// The after-run is written back-to-front: `graceNotesAfter` is the
    /// sounding order, and MuseScore rebuilds it by filtering its file
    /// order **in reverse** (`Chord::graceNotesAfter()`). Mirror of
    /// `VoiceGraceAttachmentTests.afterOrderIsReversed` on the decode
    /// side; together they pin the round trip.
    @Test("Multiple after-graces are written in reverse sounding order")
    func afterGracesWrittenReversed() throws {
        let g1 = GraceChord(
            graceType: .grace16after, duration: .sixteenth,
            notes: ChordNotes([Note(pitch: 67, tpc: 15)]),
        )
        let g2 = GraceChord(
            graceType: .grace32after, duration: .thirtySecond,
            notes: ChordNotes([Note(pitch: 69, tpc: 17)]),
        )
        let voice = Voice(elements: [
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 65, tpc: 13)]),
                graceNotesAfter: [g1, g2],
            )),
        ])

        let chordNodes = try voice.encode().all("Chord")
        #expect(chordNodes.count == 3)
        guard chordNodes.count == 3 else { return }
        #expect(chordNodes.map { $0.all("Note").map(\.pitch) } == [[69], [67], [65]])
    }

    /// Multiple before-graces must preserve mscx (array) order in the
    /// emitted sibling sequence — mirrors
    /// `VoiceGraceAttachmentTests.beforeOrder` on the decode side.
    @Test("Multiple before-graces preserve array order")
    func multipleBeforeGracesPreserveOrder() throws {
        let g1 = GraceChord(graceType: .grace16, duration: .sixteenth, notes: ChordNotes([Note(pitch: 64, tpc: 18)]))
        let g2 = GraceChord(graceType: .grace16, duration: .sixteenth, notes: ChordNotes([Note(pitch: 65, tpc: 13)]))
        let voice = Voice(elements: [
            .chord(Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
                graceNotesBefore: [g1, g2],
            )),
        ])

        let voiceNode = try voice.encode()
        let chordNodes = voiceNode.all("Chord")
        #expect(chordNodes.count == 3)
        #expect(chordNodes.prefix(2).map { $0.all("Note").map(\.pitch) } == [[64], [65]])
    }

    /// Pins the fix for the grace-tie `<location>` gap: a grace note's
    /// `tieForward` must not encode as a bare, location-less `<next/>`.
    /// Cross-referenced against MuseScore Studio's own C++ source
    /// (`src/engraving/rw/write/connectorinfowriter.cpp`, `.../rw/read460/
    /// connectorinforeader.cpp`, `.../dom/location.cpp`) rather than
    /// guessed: a grace chord shares its parent chord's tick, so a
    /// tied acciaccatura into its own main note is a zero-delta,
    /// same-measure tie — MuseScore's writer represents that as a
    /// *present but empty* `<location/>` (every field equals its
    /// default and is elided), not as an absent `<location>`. The
    /// distinction is load-bearing on reload: `ConnectorInfoReader`
    /// treats an absent `<location>` as "position unknown"
    /// (`measure == INT_MIN`), which makes `hasNext()` false and
    /// silently drops the tie when MuseScore Studio reopens the file —
    /// see `TieLocation.graceZeroDelta`'s doc comment for the full
    /// citation trail.
    @Test("A grace note's forward tie carries an empty <location>, not a bare <next/>")
    func graceTieForwardCarriesEmptyLocation() {
        let grace = GraceChord(
            graceType: .acciaccatura,
            duration: .sixteenth,
            notes: ChordNotes([Note(pitch: 59, tpc: 11, tieForward: 1)]),
        )

        let chordNode = grace.encode()
        let noteNode = chordNode.first("Note")
        let spanner = noteNode?.all("Spanner").first { $0.attributes["type"] == "Tie" }
        #expect(spanner != nil)
        guard let spanner else { return }

        #expect(spanner.hasChild("Tie"))
        let next = spanner.first("next")
        #expect(next != nil)
        guard let next else { return }

        // The bug: previously `<next>` had no children at all (nil
        // location). The fix: `<next>` carries a `<location>` element —
        // present, but with no children, matching MuseScore's own
        // default-value elision for a zero-delta tie.
        #expect(next.children.count == 1)
        let location = next.first("location")
        #expect(location != nil)
        #expect(location?.children.isEmpty == true)
    }

    /// Symmetric with the forward case: a grace note's `tieBack` (e.g.
    /// a `grace8after` tied back into the main chord it follows) must
    /// carry the same empty `<location>` under `<prev>`.
    @Test("A grace note's backward tie carries an empty <location>, not a bare <prev/>")
    func graceTieBackCarriesEmptyLocation() {
        let grace = GraceChord(
            graceType: .grace8after,
            duration: .eighth,
            notes: ChordNotes([Note(pitch: 64, tpc: 18, tieBack: 1)]),
        )

        let chordNode = grace.encode()
        let noteNode = chordNode.first("Note")
        let spanner = noteNode?.all("Spanner").first { $0.attributes["type"] == "Tie" }
        #expect(spanner != nil)
        guard let spanner else { return }

        #expect(!spanner.hasChild("Tie")) // <Tie/> marks only the forward side
        let prev = spanner.first("prev")
        #expect(prev != nil)
        guard let prev else { return }

        #expect(prev.children.count == 1)
        let location = prev.first("location")
        #expect(location != nil)
        #expect(location?.children.isEmpty == true)
    }

    /// A grace chord's duration is written straight through, never run
    /// past the tuplet un-scaling an ordinary chord's duration gets —
    /// see `GraceChord.encode`'s doc comment. Encode a before-grace
    /// attached to the first member of a triplet and confirm the
    /// grace's own `<durationType>` still reads the unscaled name.
    @Test("Grace duration inside a tuplet is not un-scaled")
    func graceDurationNotUnscaledInsideTuplet() throws {
        let grace = GraceChord(
            graceType: .acciaccatura,
            duration: .eighth,
            notes: ChordNotes([Note(pitch: 62, tpc: 16)]),
        )
        let scaledQuarter = NoteDuration.fraction(.init(numerator: 1, denominator: 6))
        let voice = Voice(
            elements: [
                .chord(Chord(
                    duration: scaledQuarter,
                    notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
                    graceNotesBefore: [grace],
                )),
                .chord(Chord(duration: scaledQuarter, notes: ChordNotes([Note(pitch: 62, tpc: 16)]))),
                .chord(Chord(duration: scaledQuarter, notes: ChordNotes([Note(pitch: 64, tpc: 18)]))),
            ],
            tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: 2)],
        )

        let voiceNode = try voice.encode()
        let chordNodes = voiceNode.all("Chord")
        #expect(chordNodes.count == 4)
        guard chordNodes.count == 4 else { return }
        // The grace chord (first <Chord>) keeps its own eighth —
        // NOT the 1/6-fraction the tuplet-scaled main chord gets.
        #expect(chordNodes[0].first("durationType")?.text == "eighth")
        #expect(!chordNodes[0].hasChild("duration"))
    }
}

extension XMLTreeNode {
    fileprivate var pitch: Int? {
        first("pitch").flatMap { Int($0.text) }
    }

    fileprivate func hasChild(_ name: String) -> Bool {
        children.contains { $0.name == name }
    }
}

@Suite("Grace note encoding — round trip")
struct GraceNoteEncoderRoundTripTests {
    @Test("grace-notes.mscx survives parse → encode → parse (v4 target)")
    func roundTripPreservesFingerprintV4() throws {
        let originalData = try MSCXFixtureLoader.mscxData("grace-notes")
        let original = try MSCXParser.parse(originalData)
        #expect(hasGraceNotes(original))

        let mscz = try MSCZWriter.write(score: original, options: .init(targetVersion: .v4))
        let roundTripped = try MSCZReader.parse(mscz)

        #expect(roundTripped.stableFingerprint == original.stableFingerprint)
    }

    @Test("grace-notes.mscx survives parse → encode → parse (v3 target)")
    func roundTripPreservesFingerprintV3() throws {
        let originalData = try MSCXFixtureLoader.mscxData("grace-notes")
        let original = try MSCXParser.parse(originalData)
        #expect(hasGraceNotes(original))

        let mscz = try MSCZWriter.write(score: original, options: .init(targetVersion: .v3))
        let roundTripped = try MSCZReader.parse(mscz)

        #expect(roundTripped.stableFingerprint == original.stableFingerprint)
    }

    /// Sanity check that the fixture actually exercises what these
    /// tests claim to cover — a fixture that decoded to zero grace
    /// notes would make the fingerprint assertion above vacuously true.
    private func hasGraceNotes(_ score: Score) -> Bool {
        for part in score.parts {
            for staff in part.staves {
                for measure in staff.measures {
                    for voice in measure.voices {
                        for element in voice.elements {
                            guard case let .chord(chord) = element else { continue }
                            if !chord.graceNotesBefore.isEmpty || !chord.graceNotesAfter.isEmpty {
                                return true
                            }
                        }
                    }
                }
            }
        }
        return false
    }
}
