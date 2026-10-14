import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// A begin side hidden with `<visible>0</visible>` on its payload is still a begin side: it keeps its payload and
/// `<next>` through decode -> encode -> decode, and it still plays (MuseScore plays a hidden rit. and hairpin). The
/// payload-less `<prev>` end marker is the other side: it neither draws nor plays. The side is `isEndMarker`;
/// `visible` is visibility alone.
@Suite("Hidden spanner codec")
struct HiddenSpannerCodecTests {
    private static let next = "<next><location><measures>1</measures></location></next>"

    private static func decode(_ xml: String) throws -> Spanner {
        try Spanner.decode(XMLTreeParser.parse(Data(xml.utf8)))
    }

    private static func hiddenRit() throws -> Spanner {
        try decode("""
        <Spanner type="GradualTempoChange"><GradualTempoChange>
        <tempoChangeType>ritardando</tempoChangeType><tempoEasingMethod>ease-in</tempoEasingMethod>
        <tempoChangeFactor>0.5</tempoChangeFactor><beginText>rit.</beginText><visible>0</visible>
        </GradualTempoChange>\(next)</Spanner>
        """)
    }

    private static func hiddenHairpin() throws -> Spanner {
        try decode("""
        <Spanner type="HairPin"><HairPin><subtype>0</subtype><visible>0</visible></HairPin>\(next)</Spanner>
        """)
    }

    private static func endMarker(_ type: String) throws -> Spanner {
        try decode("<Spanner type=\"\(type)\"><prev><location><measures>-1</measures></location></prev></Spanner>")
    }

    private static func has(_ child: String, in node: XMLTreeNode) -> Bool {
        node.children.contains { $0.name == child }
    }

    @Test("a hidden begin side is a begin side that is not visible")
    func sideIsIndependentOfVisibility() throws {
        let hidden = try Self.hiddenRit()
        #expect(!hidden.isEndMarker)
        #expect(!hidden.visible)
        let marker = try Self.endMarker("GradualTempoChange")
        #expect(marker.isEndMarker)
        #expect(!marker.visible)
        let shown = try Self.decode(
            "<Spanner type=\"HairPin\"><HairPin><subtype>0</subtype></HairPin>\(Self.next)</Spanner>",
        )
        #expect(!shown.isEndMarker)
        #expect(shown.visible)
    }

    @Test("a hidden rit. round-trips with type, factor, easing, text and <next> intact")
    func hiddenRitRoundTrips() throws {
        let hidden = try Self.hiddenRit()
        let encoded = hidden.encode()
        #expect(!Self.has("prev", in: encoded))
        let payload = try #require(encoded.first("GradualTempoChange"))
        #expect(payload.first("visible")?.text == "0")
        #expect(payload.first("tempoChangeType")?.text == "ritardando")
        #expect(Self.has("next", in: encoded))

        let again = try Spanner.decode(encoded)
        let change = try #require(again.gradualTempoChange)
        #expect(change.type == .ritardando)
        #expect(change.factor == 0.5)
        #expect(change.easing == .easeIn)
        #expect(change.playsBack)
        #expect(again.beginText == "rit.")
        #expect(again.nextMeasuresOffset == 1)
        #expect(!again.isEndMarker)
        #expect(!again.visible)
        #expect(again.encode() == encoded)
    }

    @Test("a hidden rit. still ramps the tempo map, as a visible one does")
    func hiddenRitStillRamps() throws {
        let hidden = try Spanner.decode(Self.hiddenRit().encode())
        var shown = hidden
        shown.visible = true
        func rampSpeeds(_ spanner: Spanner) -> [Double] {
            TempoMapFixtures.score(
                measures: 3, lane: [TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 2))],
                ramps: [(measure: 0, spanner: spanner)],
            ).resolvedTempoMap().points.filter { $0.role == .ramp }.map(\.beatsPerSecond)
        }
        let speeds = rampSpeeds(hidden)
        #expect(!speeds.isEmpty)
        #expect(speeds == rampSpeeds(shown))
        let last = try #require(speeds.last)
        #expect(last < 2)
    }

    @Test("an end marker adds nothing to the tempo map")
    func endMarkerDoesNotRamp() throws {
        let marker = try Self.endMarker("GradualTempoChange")
        let map = TempoMapFixtures.score(
            measures: 3, lane: [TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 2))],
            ramps: [(measure: 0, spanner: marker)],
        ).resolvedTempoMap()
        #expect(map.points.filter { $0.role == .ramp }.isEmpty)
    }

    private func wedges(_ spanner: Spanner, closingWith end: Spanner? = nil) -> [HairpinRamp] {
        func quarter() -> VoiceElement {
            .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)])))
        }
        let first = Measure(voices: [Voice(elements: [
            .dynamic(Dynamic(subtype: "mp", velocity: 64)), .spanner(spanner),
        ] + Array(repeating: quarter(), count: 4))])
        let closing = (end.map { [VoiceElement.spanner($0)] } ?? []) + Array(repeating: quarter(), count: 4)
        let second = Measure(voices: [Voice(elements: [.dynamic(Dynamic(subtype: "f", velocity: 96))] + closing)])
        return HairpinRamps.collect(
            voiceIndex: 0, staff: Staff(measures: [first, second]),
            instrument: Instrument(id: "piano", articulations: []), division: 480, tempoMap: ResolvedTempoMap(),
        ).filter { $0.role == .wedge }
    }

    @Test("a hidden hairpin round-trips and still shapes velocity")
    func hiddenHairpinRoundTripsAndPlays() throws {
        let hidden = try Self.hiddenHairpin()
        let encoded = hidden.encode()
        #expect(encoded.first("HairPin")?.first("visible")?.text == "0")
        #expect(Self.has("next", in: encoded))
        let again = try Spanner.decode(encoded)
        #expect(again.hairpin?.subtype == .crescendo)
        #expect(!again.visible && !again.isEndMarker)
        let ramps = try wedges(again, closingWith: Self.endMarker("HairPin"))
        #expect(ramps.count == 1)
        #expect(ramps.first?.startVelocity == 64)
        #expect(ramps.first?.endVelocity == 96)
    }

    @Test("an end marker re-encodes as a bare <prev/> and never plays")
    func endMarkerIsInertAndSurvives() throws {
        let marker = try Self.endMarker("HairPin")
        #expect(marker.hairpin == nil)
        let encoded = marker.encode()
        #expect(Self.has("prev", in: encoded))
        #expect(!Self.has("HairPin", in: encoded))
        #expect(try Spanner.decode(encoded).isEndMarker)
        #expect(wedges(marker).isEmpty)
    }

    @Test("a hidden begin side and an end marker are different scores")
    func fingerprintTellsTheSidesApart() throws {
        let hidden = try Self.hiddenHairpin()
        var marker = hidden
        marker.isEndMarker = true
        func fingerprint(_ spanner: Spanner) -> Int64 {
            TempoMapFixtures.score(measures: 1, ramps: [(measure: 0, spanner: spanner)]).stableFingerprint
        }
        #expect(fingerprint(hidden) != fingerprint(marker))
    }

    @Test("the initializer reads visible: false as an end marker unless told otherwise")
    func initializerDerivesTheSide() {
        #expect(Spanner(kind: .slur, rawType: "Slur", visible: false).isEndMarker)
        #expect(!Spanner(kind: .slur, rawType: "Slur").isEndMarker)
        #expect(!Spanner(kind: .slur, rawType: "Slur", visible: false, isEndMarker: false).isEndMarker)
    }
}
