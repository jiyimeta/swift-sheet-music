import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

struct SmallNoteTests {
    private func parseNote(_ xml: String) throws -> Note {
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        return try Note.decode(node)
    }

    @Test func decodesSmallFlag() throws {
        let xml = "<Note><pitch>60</pitch><tpc>14</tpc><small>1</small></Note>"
        #expect(try parseNote(xml).isSmall == true)
    }

    @Test func defaultsFalse() throws {
        let xml = "<Note><pitch>60</pitch><tpc>14</tpc></Note>"
        #expect(try parseNote(xml).isSmall == false)
    }

    private func parseChord(_ xml: String) throws -> Chord {
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        return try Chord.decode(node)
    }

    /// `Note.isSmall` used to be decode-only: the decoder read `<small>` and
    /// the encoder had no arm for it, so a cue note was silently dropped on
    /// save. The 2-pass byte gate cannot see that — it compares pass 1 against
    /// pass 2, and both dropped it.
    @Test("an all-small chord re-encodes the chord-level <small>, immediately before <durationType>")
    func allSmallChordEncodesChordLevelSmall() throws {
        let chord = try parseChord("""
        <Chord><small>1</small><durationType>eighth</durationType>\
        <Note><pitch>71</pitch><tpc>19</tpc></Note>\
        <Note><pitch>74</pitch><tpc>16</tpc></Note></Chord>
        """)
        #expect(chord.notes.map(\.isSmall) == [true, true])

        let encoded = chord.encodeAsChord(eid: .invalid)
        #expect(encoded.first("small")?.text == "1")
        let names = encoded.children.map(\.name)
        #expect(names.firstIndex(of: "small").map { $0 + 1 } == names.firstIndex(of: "durationType"))
        // The flag lives on the chord OR on the notes, never on both: MuseScore
        // keeps them as two separate properties and writes whichever was set.
        let noteSmalls = encoded.all("Note").map { $0.first("small") }
        #expect(noteSmalls == [nil, nil])
    }

    /// A chord only some of whose notes are small has no chord-level form to
    /// write — the flag goes on each small note, between `<tpc>` and `<head>`.
    @Test("a partly small chord re-encodes note-level <small> on the small note only")
    func mixedChordEncodesNoteLevelSmall() throws {
        let chord = try parseChord("""
        <Chord><durationType>quarter</durationType>\
        <Note><pitch>71</pitch><tpc>19</tpc><small>1</small><head>cross</head></Note>\
        <Note><pitch>74</pitch><tpc>16</tpc></Note></Chord>
        """)

        let encoded = chord.encodeAsChord(eid: .invalid)
        #expect(encoded.all("small").isEmpty)
        let noteNodes = encoded.all("Note")
        #expect(noteNodes.count == 2)
        let small = try #require(noteNodes.first)
        #expect(small.first("small")?.text == "1")
        let names = small.children.map(\.name)
        #expect(names.firstIndex(of: "tpc").map { $0 + 1 } == names.firstIndex(of: "small"))
        #expect(names.firstIndex(of: "small").map { $0 + 1 } == names.firstIndex(of: "head"))
        let plain = try #require(noteNodes.last)
        #expect(plain.all("small").isEmpty)
    }

    /// The known normalization, pinned rather than wished away: the model holds
    /// one flag per note and no chord-level field, so a file that spelled the
    /// flag on every `<Note>` comes back out in the chord-level spelling. In
    /// MuseScore those are different properties — `ChordRest.small` scales the
    /// stem and hook, `Note.small` only the notehead — so this can change how a
    /// re-saved file renders. Recorded in `docs/musescore-model-parity.md` §5.2;
    /// this test exists so the promotion cannot change unnoticed.
    @Test("a chord whose every note spelled <small> itself is promoted to the chord-level form")
    func allNoteLevelSmallIsPromotedToChordLevel() throws {
        let chord = try parseChord("""
        <Chord><durationType>quarter</durationType>\
        <Note><pitch>71</pitch><tpc>19</tpc><small>1</small></Note>\
        <Note><pitch>74</pitch><tpc>16</tpc><small>1</small></Note></Chord>
        """)

        let encoded = chord.encodeAsChord(eid: .invalid)
        #expect(encoded.first("small")?.text == "1")
        let noteSmalls = encoded.all("Note").map { $0.first("small") }
        #expect(noteSmalls == [nil, nil])
    }

    /// A grace is written as a `<Chord>` and read back by `Chord.decode`, so it
    /// has to spell the flag the same way an ordinary chord does — cue graces
    /// are where `<small>` turns up most often in real scores.
    @Test("a small grace chord re-encodes the chord-level <small>")
    func smallGraceChordEncodesChordLevelSmall() throws {
        let node = try XMLTreeParser.parse(Data("""
        <Chord><small>1</small><durationType>eighth</durationType><acciaccatura/>\
        <Note><pitch>71</pitch><tpc>19</tpc></Note></Chord>
        """.utf8))
        let graceType = try #require(Chord.graceType(in: node))
        let inner = try Chord.decode(node)
        #expect(inner.notes.map(\.isSmall) == [true])

        let grace = GraceChord(graceType: graceType, duration: inner.duration, notes: inner.notes)
        let encoded = grace.encode(eid: .invalid)
        #expect(encoded.first("small")?.text == "1")
        let names = encoded.children.map(\.name)
        #expect(names.firstIndex(of: "small").map { $0 + 1 } == names.firstIndex(of: "durationType"))
        let noteNode = try #require(encoded.all("Note").first)
        #expect(noteNode.all("small").isEmpty)
    }

    /// Both shapes must survive a second trip, or the idempotency gate would
    /// start failing on any score containing a cue note.
    @Test("both small shapes round-trip through decode → encode → decode")
    func smallShapesAreIdempotent() throws {
        for xml in [
            "<Chord><small>1</small><durationType>eighth</durationType>"
                + "<Note><pitch>71</pitch><tpc>19</tpc></Note></Chord>",
            "<Chord><durationType>quarter</durationType>"
                + "<Note><pitch>71</pitch><tpc>19</tpc><small>1</small></Note>"
                + "<Note><pitch>74</pitch><tpc>16</tpc></Note></Chord>",
        ] {
            let first = try parseChord(xml)
            let second = try Chord.decode(first.encodeAsChord(eid: .invalid))
            #expect(second.notes.map(\.isSmall) == first.notes.map(\.isSmall))
        }
    }
}
