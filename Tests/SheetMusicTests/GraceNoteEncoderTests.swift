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
    /// A minimal `<voice>` with one main chord flanked by a
    /// before-grace and an after-grace. Encoding it must emit three
    /// sibling `<Chord>` nodes, in this order, and the grace ones must
    /// carry their own grace-type tag rather than being folded into
    /// (or dropped from) the main chord's node.
    @Test("Before- and after-graces are emitted as sibling <Chord> nodes, in order")
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

        // 2. The main chord: no grace tag, carries the main note
        // (pitch 60) and neither grace's note.
        for graceTag in GraceType.allCases.map(\.mscxTag) {
            #expect(!chordNodes[1].hasChild(graceTag))
        }
        #expect(chordNodes[1].all("Note").map(\.pitch) == [60])

        // 3. The after-grace: its own <Chord>, tagged <grace8after/>,
        // carrying only its own note (pitch 64).
        #expect(chordNodes[2].hasChild("grace8after"))
        #expect(chordNodes[2].all("Note").map(\.pitch) == [64])
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
