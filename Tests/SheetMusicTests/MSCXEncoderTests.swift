import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite("MSCXEncoder")
struct MSCXEncoderTests {
    @Test("minimal Score round-trips division and metaTags")
    func minimalScoreRoundTrip() throws {
        let original = Score(
            division: 480,
            metaTags: ["composer": "Bach", "workTitle": "Invention"]
        )

        let bytes = try MSCXEncoder.encode(original)
        let reparsed = try MSCXParser.parse(bytes)

        #expect(reparsed.division == 480)
        #expect(reparsed.metaTags == original.metaTags)
    }

    @Test("Score round-trips custom spatium")
    func spatiumRoundTrip() throws {
        var style = ScoreStyle.museScoreDefaults
        style.spatium = 1.5
        let original = Score(division: 480, style: style)

        let bytes = try MSCXEncoder.encode(original)
        let reparsed = try MSCXParser.parse(bytes)

        #expect(reparsed.style.spatium == 1.5)
    }

    @Test("Note encodes pitch + tpc and round-trips")
    func noteRoundTrip() throws {
        let note = Note(pitch: 60, tpc: 14)
        let xml = note.encode()
        // re-parse via the full pipeline
        let document = XMLTreeNode(name: "root", children: [xml])
        let bytes = XMLTreeSerializer.serialize(document)
        let reparsed = try XMLTreeParser.parse(bytes)
        let noteNode = try #require(reparsed.first("Note"))
        let decoded = try Note.decode(noteNode)
        #expect(decoded == note)
    }

    @Test("Note round-trips every Accidental case")
    func accidentalRoundTrip() throws {
        let cases: [Accidental] = [.sharp, .flat, .natural, .doubleSharp, .doubleFlat]
        for acc in cases {
            let note = Note(pitch: 61, tpc: 21, accidental: acc)
            let document = XMLTreeNode(name: "root", children: [note.encode()])
            let bytes = XMLTreeSerializer.serialize(document)
            let reparsed = try XMLTreeParser.parse(bytes)
            let noteNode = try #require(reparsed.first("Note"))
            let decoded = try Note.decode(noteNode)
            #expect(decoded.accidental == acc, "accidental \(acc) failed to round-trip")
        }
    }

    @Test("NoteDuration appends durationType for named cases")
    func durationTypeNamed() {
        var children: [XMLTreeNode] = []
        NoteDuration.quarter.appendDurationXML(to: &children)
        #expect(children.count == 1)
        #expect(children[0].name == "durationType")
        #expect(children[0].text == "quarter")
    }

    @Test("NoteDuration appends durationType=measure + duration for fractions")
    func durationTypeFraction() {
        var children: [XMLTreeNode] = []
        NoteDuration.fraction(.init(numerator: 3, denominator: 8))
            .appendDurationXML(to: &children)
        #expect(children.count == 2)
        #expect(children[0].name == "durationType")
        #expect(children[0].text == "measure")
        #expect(children[1].name == "duration")
        #expect(children[1].text == "3/8")
    }

    @Test("Chord round-trips through Chord.decode")
    func chordRoundTrip() throws {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)])
        )
        let xml = chord.encodeAsChord()
        let document = XMLTreeNode(name: "root", children: [xml])
        let bytes = XMLTreeSerializer.serialize(document)
        let reparsed = try XMLTreeParser.parse(bytes)
        let chordNode = try #require(reparsed.first("Chord"))
        let decoded = try Chord.decode(chordNode)
        #expect(decoded == chord)
    }

    @Test("rest chord emits as <Rest>")
    func restEmitsAsRestElement() {
        let rest = Chord(duration: .quarter, notes: [])
        let xml = rest.encodeAsRest()
        #expect(xml.name == "Rest")
        #expect(xml.first("durationType")?.text == "quarter")
    }

    @Test("KeySignature, TimeSignature, Clef round-trip")
    func staticElementsRoundTrip() throws {
        func roundTripParse<T>(_ node: XMLTreeNode, name: String, _ decode: (XMLTreeNode) throws -> T) throws -> T {
            let bytes = XMLTreeSerializer.serialize(
                XMLTreeNode(name: "root", children: [node])
            )
            let reparsed = try XMLTreeParser.parse(bytes)
            return try decode(#require(reparsed.first(name)))
        }

        let key = KeySignature(concertKey: 1)
        let decKey = try roundTripParse(key.encode(), name: "KeySig", KeySignature.decode)
        #expect(decKey == key)

        let time = TimeSignature(numerator: 4, denominator: 4)
        let decTime = try roundTripParse(time.encode(), name: "TimeSig", TimeSignature.decode)
        #expect(decTime == time)

        let clef = Clef(concertClefType: "G")
        let decClef = try roundTripParse(clef.encode(), name: "Clef", Clef.decode)
        #expect(decClef == clef)
    }

    @Test("Voice round-trips KeySig + TimeSig + two chords")
    func voiceRoundTrip() throws {
        let original = Voice(elements: [
            .keySignature(KeySignature(concertKey: 1)),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
            .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 62, tpc: 16)]))),
        ])
        let xml = original.encode()
        let bytes = XMLTreeSerializer.serialize(XMLTreeNode(name: "root", children: [xml]))
        let reparsed = try XMLTreeParser.parse(bytes)
        let voiceNode = try #require(reparsed.first("voice"))
        let decoded = try Voice.decode(voiceNode)
        #expect(decoded == original)
    }

    @Test("Measure round-trips a single voice")
    func measureRoundTrip() throws {
        let voice = Voice(elements: [
            .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
        ])
        let measure = Measure(voices: [voice])

        let xml = measure.encode()
        let bytes = XMLTreeSerializer.serialize(XMLTreeNode(name: "root", children: [xml]))
        let reparsed = try XMLTreeParser.parse(bytes)
        let measureNode = try #require(reparsed.first("Measure"))
        let decoded = try Measure.decode(measureNode)
        #expect(decoded == measure)
    }

    @Test("InstrumentArticulation default + named round-trip")
    func articulationRoundTrip() throws {
        let cases = [
            InstrumentArticulation(name: nil, velocity: 100, gateTime: 100),
            InstrumentArticulation(name: "staccato", velocity: 100, gateTime: 50),
        ]
        for art in cases {
            let xml = art.encode()
            let bytes = XMLTreeSerializer.serialize(XMLTreeNode(name: "root", children: [xml]))
            let reparsed = try XMLTreeParser.parse(bytes)
            let artNode = try #require(reparsed.first("Articulation"))
            let decoded = try InstrumentArticulation.decode(artNode)
            #expect(decoded == art)
        }
    }

    @Test("InstrumentChannel program-only round-trip matches default fields")
    func channelProgramRoundTrip() throws {
        let original = InstrumentChannel(program: 52)
        let xml = original.encode()
        let bytes = XMLTreeSerializer.serialize(XMLTreeNode(name: "root", children: [xml]))
        let reparsed = try XMLTreeParser.parse(bytes)
        let channelNode = try #require(reparsed.first("Channel"))
        let decoded = try InstrumentChannel.decode(channelNode)
        #expect(decoded == original)
    }

    @Test("InstrumentChannel non-default volume emits controller and round-trips")
    func channelNonDefaultControllerRoundTrip() throws {
        var channel = InstrumentChannel(program: 0)
        channel.volume = 80
        channel.pan = 30
        let xml = channel.encode()
        let bytes = XMLTreeSerializer.serialize(XMLTreeNode(name: "root", children: [xml]))
        let reparsed = try XMLTreeParser.parse(bytes)
        let channelNode = try #require(reparsed.first("Channel"))
        let decoded = try InstrumentChannel.decode(channelNode)
        #expect(decoded.volume == 80)
        #expect(decoded.pan == 30)
    }

    @Test("Instrument round-trip with articulations + channel")
    func instrumentRoundTrip() throws {
        let original = Instrument(
            id: "voice",
            longName: "Voice",
            shortName: "Vo.",
            trackName: "Voice",
            minPitchPlayable: 38,
            maxPitchPlayable: 84,
            minPitchAmateur: 41,
            maxPitchAmateur: 79,
            articulations: [
                InstrumentArticulation(),
                InstrumentArticulation(name: "staccato", velocity: 100, gateTime: 50),
            ],
            channels: [InstrumentChannel(program: 52)]
        )
        let xml = original.encode()
        let bytes = XMLTreeSerializer.serialize(XMLTreeNode(name: "root", children: [xml]))
        let reparsed = try XMLTreeParser.parse(bytes)
        let instrumentNode = try #require(reparsed.first("Instrument"))
        let decoded = try Instrument.decode(instrumentNode)
        #expect(decoded == original)
    }
}
