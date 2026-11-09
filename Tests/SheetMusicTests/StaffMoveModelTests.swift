import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// MuseScore's cross-staff notation in the model: a `<Chord>` or `<Rest>` carrying `<staffMove>±1</staffMove>` is drawn
/// on the adjacent staff of its part. Read as `TRead::readProperties(ChordRest*)` reads it
/// (`rw/read460/tread.cpp:2610-2612`; MuseScore 2's `<move>`, `rw/read206/read206.cpp:1762`), written as
/// `TWrite::writeProperties(const ChordRest*)` writes it (`rw/write/twrite.cpp:1109`: after `<dots>`, before
/// `<durationType>`, only when non-zero), and honored only where `ChordRest::checkStaffMoveValidity`
/// (`dom/chordrest.cpp:1302-1336`) would honor it.
@Suite("Chord / Rest <staffMove>: model, codec, resolver")
struct StaffMoveModelTests {
    private typealias Fixture = CrossStaffFixture

    // MARK: - Decode / encode

    @Test("<staffMove> reads onto a chord and a rest, MuseScore 2's <move> too, and is not preserved markup")
    func decodes() throws {
        let treble = Fixture.chord([(48, 14)], move: 1) + Fixture.rest(move: 1)
            + "<Chord><move>1</move><durationType>quarter</durationType><Note><pitch>50</pitch><tpc>16</tpc></Note>"
            + "</Chord>" + Fixture.chord([(60, 14)])
        let score = try Fixture.parse(Fixture.piano(treble: [treble], bass: [Fixture.rest("measure")]))
        let chords = Fixture.chords(score, staff: 0)
        #expect(chords.map(\.staffMove) == [1, 1, 1, 0])
        #expect(chords.allSatisfy { !$0.preservedMarkup.map(\.name).contains("staffMove") })
        #expect(chords.allSatisfy { !$0.preservedMarkup.map(\.name).contains("move") })
    }

    @Test("a chord and a rest write <staffMove> after <dots>, before <durationType>, only when non-zero")
    func encodesInMuseScoresSlot() throws {
        let treble = Fixture.chord([(48, 14)], move: 1, extra: "<dots>1</dots>")
            + Fixture.chord([(60, 14)], "eighth") + Fixture.rest(move: 1)
        let original = try Fixture.parse(Fixture.piano(treble: [treble], bass: [Fixture.rest("measure")]))
        let text = try #require(String(bytes: MSCXEncoder.encode(original), encoding: .utf8))
        #expect(text.components(separatedBy: "<staffMove>").count == 3)
        let dots = try #require(text.range(of: "<dots>1</dots>"))
        let move = try #require(text.range(of: "<staffMove>1</staffMove>"))
        let type = try #require(text.range(of: "<durationType>quarter</durationType>"))
        #expect(dots.upperBound <= move.lowerBound)
        #expect(move.upperBound <= type.lowerBound)
        // The rest's: right before its own `<durationType>`.
        let restOpen = try #require(text.range(of: "<Rest>", range: type.upperBound ..< text.endIndex))
        let afterRest = restOpen.upperBound ..< text.endIndex
        let restMove = try #require(text.range(of: "<staffMove>1</staffMove>", range: afterRest))
        let restType = try #require(text.range(of: "<durationType>", range: afterRest))
        #expect(restMove.upperBound <= restType.lowerBound)
        let reread = try Fixture.parse(Data(text.utf8))
        #expect(Fixture.chords(reread, staff: 0).map(\.staffMove) == [1, 0, 1])
    }

    @Test("a move the score cannot honor is still written back as the file had it")
    func invalidMoveRoundTrips() throws {
        let treble = Fixture.chord([(48, 14)], move: 3)
        let original = try Fixture.parse(Fixture.piano(treble: [treble], bass: [Fixture.rest("measure")]))
        let text = try #require(String(bytes: MSCXEncoder.encode(original), encoding: .utf8))
        #expect(text.contains("<staffMove>3</staffMove>"))
    }

    @Test("a grace chord's <staffMove> stays its preserved markup and round-trips")
    func graceKeepsItsMove() throws {
        let grace = "<Chord><acciaccatura/><staffMove>1</staffMove><durationType>eighth</durationType>"
            + "<Note><pitch>47</pitch><tpc>19</tpc></Note></Chord>"
        let treble = grace + Fixture.chord([(48, 14)], move: 1)
        let original = try Fixture.parse(Fixture.piano(treble: [treble], bass: [Fixture.rest("measure")]))
        let chord = try #require(Fixture.chords(original, staff: 0).first)
        #expect(chord.staffMove == 1)
        #expect(chord.graceNotesBefore.values.first?.preservedMarkup.map(\.name) == ["staffMove"])
        let text = try #require(String(bytes: MSCXEncoder.encode(original), encoding: .utf8))
        #expect(text.components(separatedBy: "<staffMove>1</staffMove>").count == 3)
    }

    // MARK: - Resolver

    @Test("a move onto the other staff of the part is honored, either way")
    func validMovesResolve() throws {
        let score = try Fixture.parse(Fixture.piano(
            treble: [Fixture.chord([(48, 14)], move: 1)], bass: [Fixture.chord([(60, 14)], move: -1)],
        ))
        #expect(score.parts[0].effectiveStaffMove(1, fromStaff: 0) == 1)
        #expect(score.parts[0].effectiveStaffMove(-1, fromStaff: 1) == -1)
        #expect(score.parts[0].hasEffectiveStaffMoves)
        let chord = try #require(Fixture.chords(score, staff: 0).first)
        #expect(score.effectiveStaffMove(of: chord, at: StaffAddress(partIndex: 0, staffIndexInPart: 0)) == 1)
    }

    @Test("no such staff in the part — past either end, or into the next part — resolves to 0")
    func outOfPartResolvesToZero() throws {
        let flute = """
        <Part id="2"><Staff><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
        <trackName>Flute</trackName><Instrument id="flute"><longName>Flute</longName></Instrument></Part>
        """
        let fluteStaff = "<Staff id=\"3\"><Measure><voice>\(Fixture.fourFour)\(Fixture.chord([(72, 14)], move: -1))"
            + "</voice></Measure></Staff>"
        let score = try Fixture.parse(Fixture.piano(
            treble: [Fixture.chord([(48, 14)], move: -1)], bass: [Fixture.chord([(60, 14)], move: 1)],
            trailingParts: flute, trailingStaves: fluteStaff,
        ))
        let piano = score.parts[0]
        #expect(piano.effectiveStaffMove(-1, fromStaff: 0) == 0)
        #expect(piano.effectiveStaffMove(1, fromStaff: 1) == 0)
        #expect(piano.effectiveStaffMove(2, fromStaff: 0) == 0)
        // The flute's only staff has nothing above it in its own part, though the piano's bass staff is above it.
        #expect(score.parts[1].effectiveStaffMove(-1, fromStaff: 0) == 0)
        #expect(!piano.hasEffectiveStaffMoves)
    }

    @Test("a hidden target staff resolves to 0, as does one of another staff-type group")
    func hiddenOrOtherGroupResolvesToZero() throws {
        let hidden = try Fixture.parse(Fixture.piano(
            treble: [Fixture.chord([(48, 14)], move: 1)], bass: [Fixture.rest("measure")],
            bassStaffChildren: "<isStaffVisible>0</isStaffVisible>",
        ))
        #expect(hidden.parts[0].effectiveStaffMove(1, fromStaff: 0) == 0)
        let percussion = try Fixture.parse(Fixture.piano(
            treble: [Fixture.chord([(48, 14)], move: 1)], bass: [Fixture.rest("measure")], bassGroup: "percussion",
        ))
        #expect(percussion.parts[0].effectiveStaffMove(1, fromStaff: 0) == 0)
    }

    // MARK: - The host's staff filter

    @Test("hiding the target staff drops the move; hiding a staff between re-aims it at the same staff")
    func filterRemapsMoves() throws {
        let score = try Fixture.parse(Fixture.piano(
            treble: [Fixture.chord([(48, 14)], move: 1)], bass: [Fixture.chord([(60, 14)], move: -1)],
        ))
        let withoutBass = score.filtered(hidingStaves: [StaffAddress(partIndex: 0, staffIndexInPart: 1)])
        #expect(Fixture.chords(withoutBass, staff: 0).map(\.staffMove) == [0])

        // A three-staff part (an organ): the top staff's chord names the pedal staff two below, the pedal staff's the
        // top one; with the middle staff hidden, both still name each other.
        let staffDecl = "<Staff><StaffType group=\"pitched\"><name>stdNormal</name></StaffType></Staff>"
        func measure(_ body: String) -> String {
            "<Measure><voice>\(Fixture.fourFour)\(body)</voice></Measure>"
        }
        let organ = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60"><Score><Division>480</Division>
        <Part id="1">\(staffDecl)\(staffDecl)\(staffDecl)<trackName>Organ</trackName>
        <Instrument id="organ"><longName>Organ</longName></Instrument></Part>
        <Staff id="1">\(measure(Fixture.chord([(48, 14)], "whole", move: 2)))</Staff>
        <Staff id="2">\(measure(Fixture.rest("measure")))</Staff>
        <Staff id="3">\(measure(Fixture.chord([(72, 14)], "whole", move: -2)))</Staff>
        </Score></museScore>
        """
        let three = try Fixture.parse(Data(organ.utf8))
        #expect(three.parts[0].effectiveStaffMove(2, fromStaff: 0) == 2)
        let filtered = three.filtered(hidingStaves: [StaffAddress(partIndex: 0, staffIndexInPart: 1)])
        #expect(Fixture.chords(filtered, staff: 0).map(\.staffMove) == [1])
        #expect(Fixture.chords(filtered, staff: 1).map(\.staffMove) == [-1])
    }
}
