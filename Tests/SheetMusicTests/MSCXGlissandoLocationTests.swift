import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite("MSCX glissando locations")
struct MSCXGlissandoLocationTests {
    @Test("same-bar and cross-bar glissandi write inverse endpoint locations")
    func sameAndCrossMeasureLocations() throws {
        let firstMeasure = Voice(elements: [
            .chord(Self.chord(60, glissando: true)),
            .chord(Self.chord(67)),
            .chord(Self.chord(71, glissando: true)),
        ])
        let secondMeasure = Voice(elements: [
            .chord(Self.chord(74)),
        ])

        let notes = try Self.encodedNotes(in: [firstMeasure, secondMeasure])
        try #require(notes.count == 4)

        let sameForward = try #require(Self.location(in: notes[0], side: "next"))
        #expect(!Self.hasChild(named: "measures", in: sameForward))
        #expect(sameForward.first("fractions")?.text == "1/4")
        #expect(!Self.hasChild(named: "notes", in: sameForward))
        let sameBack = try #require(Self.location(in: notes[1], side: "prev"))
        #expect(!Self.hasChild(named: "measures", in: sameBack))
        #expect(sameBack.first("fractions")?.text == "-1/4")
        #expect(!Self.hasChild(named: "notes", in: sameBack))

        let crossForward = try #require(Self.location(in: notes[2], side: "next"))
        #expect(crossForward.first("measures")?.text == "1")
        #expect(crossForward.first("fractions")?.text == "-1/2")
        #expect(!Self.hasChild(named: "notes", in: crossForward))
        let crossBack = try #require(Self.location(in: notes[3], side: "prev"))
        #expect(crossBack.first("measures")?.text == "-1")
        #expect(crossBack.first("fractions")?.text == "1/2")
        #expect(!Self.hasChild(named: "notes", in: crossBack))
    }

    @Test("three glissandi into one note write every pitch-rank delta")
    func manyToOnePitchRankDeltas() throws {
        let start = Chord(
            duration: .quarter,
            notes: ChordNotes([
                Self.note(60, glissando: true),
                Self.note(64, glissando: true),
                Self.note(67, glissando: true),
            ]),
        )
        let voice = Voice(elements: [
            .chord(start),
            .chord(Self.chord(74)),
        ])

        let notes = try Self.encodedNotes(in: [voice])
        try #require(notes.count == 4)
        #expect(Self.noteDelta(in: notes[0], side: "next") == 0)
        #expect(Self.noteDelta(in: notes[1], side: "next") == -1)
        #expect(Self.noteDelta(in: notes[2], side: "next") == -2)

        let backSpanners = Self.glissandoSpanners(in: notes[3], side: "prev")
        try #require(backSpanners.count == 3)
        #expect(Self.spannerNoteDelta(in: backSpanners[0], side: "prev") == 0)
        #expect(Self.spannerNoteDelta(in: backSpanners[1], side: "prev") == 1)
        #expect(Self.spannerNoteDelta(in: backSpanners[2], side: "prev") == 2)
    }

    @Test("insertion-order pairing is converted through pitch ranks")
    func insertionOrderPairingUsesPitchRanks() throws {
        let start = Chord(
            duration: .quarter,
            notes: ChordNotes([
                Self.note(67, glissando: true),
                Self.note(60, glissando: true),
            ]),
        )
        let end = Chord(
            duration: .quarter,
            notes: ChordNotes([
                Self.note(69),
                Self.note(62),
            ]),
        )

        let notes = try Self.encodedNotes(in: [Voice(elements: [
            .chord(start),
            .chord(end),
        ])])
        try #require(notes.count == 4)
        #expect(Self.noteDelta(in: notes[0], side: "next") == 0)
        #expect(Self.noteDelta(in: notes[1], side: "next") == 0)
        #expect(Self.noteDelta(in: notes[2], side: "prev") == 0)
        #expect(Self.noteDelta(in: notes[3], side: "prev") == 0)
    }

    /// The case that tells a pitch-rank delta from an insertion-index one: `[G4, C4]` into one note. The layout
    /// sends both into `D5`, so G4 (rank 1) needs `<notes>-1</notes>` and C4 (rank 0) none — an encoder that
    /// subtracted insertion indices would write the two the other way round.
    @Test("an insertion-order chord gliding into one note writes rank deltas, not index deltas")
    func insertionOrderManyToOneUsesPitchRanks() throws {
        let start = Chord(
            duration: .quarter,
            notes: ChordNotes([
                Self.note(67, glissando: true),
                Self.note(60, glissando: true),
            ]),
        )
        let notes = try Self.encodedNotes(in: [Voice(elements: [
            .chord(start),
            .chord(Self.chord(74)),
        ])])
        try #require(notes.count == 3)
        #expect(Self.noteDelta(in: notes[0], side: "next") == -1)
        #expect(Self.noteDelta(in: notes[1], side: "next") == 0)
        let backSpanners = Self.glissandoSpanners(in: notes[2], side: "prev")
        try #require(backSpanners.count == 2)
        #expect(Self.spannerNoteDelta(in: backSpanners[0], side: "prev") == 1)
        #expect(Self.spannerNoteDelta(in: backSpanners[1], side: "prev") == 0)
    }

    @Test("a glissando followed by a rest has only a located begin side")
    func glissandoIntoRestHasNoEndSide() throws {
        let voice = Voice(elements: [
            .chord(Self.chord(60, glissando: true)),
            .chord(Chord(duration: .quarter, notes: ChordNotes())),
            .chord(Self.chord(67)),
        ])

        let notes = try Self.encodedNotes(in: [voice])
        try #require(notes.count == 2)
        let forward = try #require(Self.location(in: notes[0], side: "next"))
        #expect(forward.first("fractions")?.text == "1/4")
        #expect(!Self.hasChild(named: "notes", in: forward))
        #expect(Self.glissandoSpanners(in: notes[1], side: "prev").isEmpty)
    }

    @Test("a chaining note writes its begin side before its end side")
    func chainingNoteWritesBeginBeforeEnd() throws {
        let voice = Voice(elements: [
            .chord(Self.chord(60, glissando: true)),
            .chord(Self.chord(64, glissando: true)),
            .chord(Self.chord(67)),
        ])

        let notes = try Self.encodedNotes(in: [voice])
        try #require(notes.count == 3)
        let spanners = notes[1].all("Spanner").filter {
            $0.attributes["type"] == "Glissando"
        }
        try #require(spanners.count == 2)
        #expect(Self.hasChild(named: "next", in: spanners[0]))
        #expect(Self.hasChild(named: "prev", in: spanners[1]))
    }

    @Test("glissando style tokens follow the target MuseScore version")
    func targetVersionStyleTokens() {
        let cases: [(Glissando.Style, String, String)] = [
            (.chromatic, "Chromatic", "CHROMATIC"),
            (.diatonic, "diatonic", "DIATONIC"),
            (.whiteKeys, "whitekeys", "WHITE_KEYS"),
            (.blackKeys, "blackkeys", "BLACK_KEYS"),
            (.portamento, "portamento", "PORTAMENTO"),
        ]

        for (style, v3Token, v4Token) in cases {
            let glissando = Glissando(style: style)
            #expect(
                glissando.encode(options: .init(targetVersion: .v3))
                    .first("glissandoStyle")?.text == v3Token,
            )
            #expect(
                glissando.encode(options: .init(targetVersion: .v2))
                    .first("glissandoStyle")?.text == v3Token,
            )
            #expect(
                glissando.encode(options: .init(targetVersion: .v4))
                    .first("glissandoStyle")?.text == v4Token,
            )
        }
    }

    @Test("decoder accepts MuseScore 3 whitekeys and blackkeys tokens")
    func decoderAcceptsMuseScore3KeyStyleTokens() throws {
        for (token, expected) in [
            ("whitekeys", Glissando.Style.whiteKeys),
            ("blackkeys", Glissando.Style.blackKeys),
        ] {
            let source = """
            <root><Note>
              <Spanner type="Glissando">
                <Glissando><glissandoStyle>\(token)</glissandoStyle></Glissando>
                <next><location><fractions>1/4</fractions></location></next>
              </Spanner>
              <pitch>60</pitch><tpc>14</tpc>
            </Note></root>
            """
            let root = try XMLTreeParser.parse(Data(source.utf8))
            let decoded = try Note.decode(#require(root.first("Note")))
            #expect(decoded.glissando?.style == expected)
        }
    }

    private static func note(_ pitch: Int, glissando: Bool = false) -> Note {
        Note(
            pitch: pitch,
            tpc: 14,
            glissando: glissando ? Glissando() : nil,
        )
    }

    private static func chord(_ pitch: Int, glissando: Bool = false) -> Chord {
        Chord(
            duration: .quarter,
            notes: ChordNotes([note(pitch, glissando: glissando)]),
        )
    }

    private static func encodedNotes(in voices: [Voice]) throws -> [XMLTreeNode] {
        let measures = voices.map { Measure(voices: [$0]) }
        let score = Score(
            division: 480,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "voice"),
                staves: [Staff(measures: measures)],
            )],
        )
        let root = try XMLTreeParser.parse(MSCXEncoder.encode(score))
        return descendants(named: "Note", in: root)
    }

    private static func descendants(
        named name: String,
        in node: XMLTreeNode,
    ) -> [XMLTreeNode] {
        var result = node.name == name ? [node] : []
        for child in node.children {
            result.append(contentsOf: descendants(named: name, in: child))
        }
        return result
    }

    private static func glissandoSpanners(
        in note: XMLTreeNode,
        side: String,
    ) -> [XMLTreeNode] {
        note.all("Spanner").filter {
            $0.attributes["type"] == "Glissando"
                && hasChild(named: side, in: $0)
        }
    }

    private static func hasChild(named name: String, in node: XMLTreeNode) -> Bool {
        node.children.contains { $0.name == name }
    }

    private static func location(
        in note: XMLTreeNode,
        side: String,
    ) -> XMLTreeNode? {
        glissandoSpanners(in: note, side: side).first?.first(side)?.first("location")
    }

    private static func noteDelta(in note: XMLTreeNode, side: String) -> Int? {
        guard let spanner = glissandoSpanners(in: note, side: side).first else {
            return nil
        }
        return spannerNoteDelta(in: spanner, side: side)
    }

    private static func spannerNoteDelta(in spanner: XMLTreeNode, side: String) -> Int {
        Int(spanner.first(side)?.first("location")?.first("notes")?.text ?? "0") ?? 0
    }
}
