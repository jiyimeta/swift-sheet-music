import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
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
            notes: ChordNotes([n]),
        )
        #expect(g.graceType == .acciaccatura)
        #expect(g.duration == .eighth)
        #expect(g.notes.count == 1)
        #expect(g == GraceChord(
            graceType: .acciaccatura,
            duration: .eighth,
            notes: ChordNotes([n]),
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
            notes: ChordNotes([Note(pitch: 62, tpc: 16)]),
        )
        let c = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            graceNotesBefore: [g],
            graceNotesAfter: [],
        )
        #expect(c.graceNotesBefore == [g])
        #expect(c.graceNotesAfter.isEmpty)
    }
}

@Suite("Chord grace detection")
struct ChordGraceDetectionTests {
    private func chordNode(_ xml: String) -> XMLTreeNode {
        guard let parsed = try? XMLTreeParser.parse(Data(xml.utf8)) else {
            fatalError("Failed to parse test XML")
        }
        return parsed
    }

    @Test("acciaccatura tag detected")
    func acciaccatura() {
        let node = chordNode("""
        <Chord><acciaccatura/><durationType>eighth</durationType>\
        <Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
        """)
        #expect(Chord.graceType(in: node) == .acciaccatura)
    }

    @Test("grace32after tag detected")
    func grace32after() {
        let node = chordNode("""
        <Chord><grace32after/><durationType>32nd</durationType>\
        <Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
        """)
        #expect(Chord.graceType(in: node) == .grace32after)
    }

    @Test("Plain chord returns nil")
    func plain() {
        let node = chordNode("""
        <Chord><durationType>quarter</durationType>\
        <Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
        """)
        #expect(Chord.graceType(in: node) == nil)
    }
}

@Suite("Voice grace attachment")
struct VoiceGraceAttachmentTests {
    private func voiceXML(_ inner: String) throws -> Voice {
        let xml = "<voice>\(inner)</voice>"
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        return try Voice.decode(node)
    }

    private func chordXML(
        _ tag: String? = nil, dur: String, pitch: Int, tpc: Int,
    ) -> String {
        let g = tag.map { "<\($0)/>" } ?? ""
        return """
        <Chord>\(g)<durationType>\(dur)</durationType>\
        <Note><pitch>\(pitch)</pitch><tpc>\(tpc)</tpc></Note></Chord>
        """
    }

    @Test("acciaccatura before main chord attaches as graceNotesBefore")
    func beforeAttaches() throws {
        let v = try voiceXML(
            chordXML("acciaccatura", dur: "eighth", pitch: 62, tpc: 16)
                + chordXML(dur: "quarter", pitch: 60, tpc: 14),
        )
        #expect(v.elements.count == 1)
        guard case let .chord(c) = v.elements[0] else {
            Issue.record("expected single .chord"); return
        }
        #expect(c.graceNotesBefore.count == 1)
        #expect(c.graceNotesBefore[0].graceType == .acciaccatura)
        #expect(c.graceNotesBefore[0].notes.first?.pitch == 62)
        #expect(c.graceNotesAfter.isEmpty)
    }

    @Test("Multiple before-graces preserve mscx order")
    func beforeOrder() throws {
        let v = try voiceXML(
            chordXML("grace16", dur: "16th", pitch: 64, tpc: 18)
                + chordXML("grace16", dur: "16th", pitch: 65, tpc: 13)
                + chordXML(dur: "quarter", pitch: 60, tpc: 14),
        )
        guard case let .chord(c) = v.elements.first else {
            Issue.record("no chord"); return
        }
        #expect(c.graceNotesBefore.map { $0.notes.first?.pitch } == [64, 65])
    }

    /// An after-grace is written *ahead of* the chord it decorates, not
    /// behind it — MuseScore's reader buffers every grace-type `<Chord>`
    /// and attaches the run to the **next** normal chord, splitting it
    /// by tag rather than by file position (see
    /// `Chord.mscxFileOrderedGraces`). Shaped after the upstream
    /// fixture `midi/midirenderer_data/grace_after.mscx`, where a
    /// `<grace8after/>` precedes the first chord of its measure.
    @Test("grace8after attaches to the FOLLOWING chord")
    func afterAttaches() throws {
        let v = try voiceXML(
            chordXML("grace8after", dur: "eighth", pitch: 62, tpc: 16)
                + chordXML(dur: "quarter", pitch: 60, tpc: 14),
        )
        #expect(v.elements.count == 1)
        guard case let .chord(c) = v.elements[0] else { return }
        #expect(c.notes.first?.pitch == 60)
        #expect(c.graceNotesAfter.count == 1)
        #expect(c.graceNotesAfter[0].graceType == .grace8after)
        #expect(c.graceNotesAfter[0].notes.first?.pitch == 62)
        #expect(c.graceNotesBefore.isEmpty)
    }

    /// The after-run is stored back-to-front relative to the order it
    /// sounds in: `Chord::graceNotesAfter()` filters MuseScore's single
    /// `m_graceNotes` vector **in reverse**. Pinned against the upstream
    /// playback expectation for
    /// `single_note_multi_appoggiatura_post` — file order
    /// `<grace32after>`A4, `<grace16after>`G4, main F4; sounding order
    /// F4 → G4 → A4.
    @Test("Multiple after-graces are reversed into sounding order")
    func afterOrderIsReversed() throws {
        let v = try voiceXML(
            chordXML("grace32after", dur: "32nd", pitch: 69, tpc: 17)
                + chordXML("grace16after", dur: "16th", pitch: 67, tpc: 15)
                + chordXML(dur: "quarter", pitch: 65, tpc: 13),
        )
        guard case let .chord(c) = v.elements.first else {
            Issue.record("no chord"); return
        }
        #expect(c.graceNotesAfter.map { $0.notes.first?.pitch } == [67, 69])
        #expect(c.graceNotesAfter.map(\.graceType) == [.grace16after, .grace32after])
    }

    /// A run containing both types splits by tag, each half keeping its
    /// own orientation — before forward, after reversed.
    @Test("A mixed run splits by tag, not by file position")
    func mixedRunSplitsByTag() throws {
        let v = try voiceXML(
            chordXML("grace16", dur: "16th", pitch: 62, tpc: 16)
                + chordXML("grace16after", dur: "16th", pitch: 71, tpc: 19)
                + chordXML("grace16after", dur: "16th", pitch: 69, tpc: 17)
                + chordXML(dur: "quarter", pitch: 60, tpc: 14),
        )
        #expect(v.elements.count == 1)
        guard case let .chord(c) = v.elements.first else {
            Issue.record("no chord"); return
        }
        #expect(c.graceNotesBefore.map { $0.notes.first?.pitch } == [62])
        #expect(c.graceNotesAfter.map { $0.notes.first?.pitch } == [69, 71])
    }

    @Test("Stranded before-graces (no following main chord) are dropped")
    func stranded() throws {
        let v = try voiceXML(chordXML("acciaccatura", dur: "eighth", pitch: 62, tpc: 16))
        #expect(v.elements.isEmpty)
    }

    /// MuseScore's grace buffer is per-measure and never flushed, so a
    /// run with no normal chord after it is dropped on its side too —
    /// mirrored here rather than preserved.
    @Test("Stranded after-grace (no following chord) is dropped")
    func strandedAfter() throws {
        let v = try voiceXML(chordXML("grace8after", dur: "eighth", pitch: 62, tpc: 16))
        #expect(v.elements.isEmpty)
    }

    /// A grace run that follows a normal chord belongs to the *next*
    /// one, never the one it happens to sit behind — the pre-fix
    /// backwards walk got this exactly wrong.
    @Test("An after-grace between two chords attaches to the later one")
    func afterGraceBetweenChordsGoesForward() throws {
        let v = try voiceXML(
            chordXML(dur: "quarter", pitch: 60, tpc: 14)
                + chordXML("grace8after", dur: "eighth", pitch: 62, tpc: 16)
                + chordXML(dur: "quarter", pitch: 64, tpc: 18),
        )
        #expect(v.elements.count == 2)
        guard case let .chord(first) = v.elements[0],
              case let .chord(second) = v.elements[1]
        else { Issue.record("expected two chords"); return }
        #expect(first.graceNotesAfter.isEmpty)
        #expect(second.graceNotesAfter.map { $0.notes.first?.pitch } == [62])
    }

    @Test("Grace inside a triplet does not consume tuplet wall-clock time")
    func graceInsideTuplet() throws {
        // <Tuplet> opens a 2/3 ratio; the inner main chord is a quarter
        // scaled to 2/3, but the acciaccatura keeps its original eighth
        // (graces don't contribute to tuplet time — see
        // CompatMidiRender::renderGraceNotesBefore).
        let v = try voiceXML("""
        <Tuplet><normalNotes>2</normalNotes><actualNotes>3</actualNotes></Tuplet>\
        \(chordXML("acciaccatura", dur: "eighth", pitch: 62, tpc: 16))\
        \(chordXML(dur: "quarter", pitch: 60, tpc: 14))\
        \(chordXML(dur: "quarter", pitch: 64, tpc: 18))\
        \(chordXML(dur: "quarter", pitch: 67, tpc: 15))\
        <endTuplet/>
        """)
        #expect(v.elements.count == 3)
        guard case let .chord(first) = v.elements[0] else {
            Issue.record("expected first triplet chord"); return
        }
        #expect(first.graceNotesBefore.count == 1)
        #expect(first.graceNotesBefore[0].graceType == .acciaccatura)
        // Grace duration is the unscaled eighth (1/8), NOT the
        // tuplet-scaled 1/12 the main chord receives.
        #expect(first.graceNotesBefore[0].duration == .eighth)
        // Main chord did get tuplet scaling (quarter × 2/3 = 1/6).
        #expect(first.duration.asFraction == Fraction(numerator: 2, denominator: 12))
    }
}
