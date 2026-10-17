import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

/// Where a queued voice element lands among a voice's chords, and the jogs that put it at its tick — the sequence
/// MuseScore's writer produces (`rw/write/twrite.cpp:3527-3593`, probe 2026-10-15).
@Suite("MusicXML direction splicer")
struct MusicXMLDirectionSplicerTests {
    private static func at(_ quarters: Int) -> Fraction {
        Fraction(numerator: quarters, denominator: 4)
    }

    private static let chord = VoiceElement.chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
    private static let forte = VoiceElement.dynamic(Dynamic(subtype: "f", velocity: 96))
    private static let piano = VoiceElement.dynamic(Dynamic(subtype: "p", velocity: 49))

    private static func shift(_ numerator: Int, _ denominator: Int) -> VoiceElement {
        .locationShift(delta: Fraction(numerator: numerator, denominator: denominator))
    }

    /// Four quarter chords, anchored at 0, 1/4, 1/2, 3/4.
    private static func bar() -> (elements: [VoiceElement], anchors: [MusicXMLChordAnchor]) {
        (
            Array(repeating: chord, count: 4),
            (0 ..< 4).map { MusicXMLChordAnchor(elementIndex: $0, start: at($0), end: at($0 + 1)) },
        )
    }

    private static func splice(_ queued: [(Fraction, VoiceElement)]) -> [VoiceElement] {
        let voice = bar()
        let items = queued.map { MusicXMLQueuedElement(tick: $0.0, element: $0.1) }
        return MusicXMLDirectionSplicer.splice(items, into: voice.elements, anchors: voice.anchors)
    }

    @Test("an empty queue changes nothing")
    func emptyQueue() {
        #expect(Self.splice([]) == Self.bar().elements)
    }

    @Test("at a chord's start the element goes just before it, with no jog")
    func atAChordStart() {
        let c = Self.chord
        #expect(Self.splice([(Self.at(1), Self.forte)]) == [c, Self.forte, c, c, c])
    }

    @Test("inside a chord it goes before the next chord, jogged back and forward")
    func insideAChord() {
        let c = Self.chord
        let eighth = Fraction(numerator: 1, denominator: 8)
        #expect(Self.splice([(eighth, Self.forte)]) == [c, Self.shift(-1, 8), Self.forte, Self.shift(1, 8), c, c, c])
    }

    @Test("after the last chord it follows the chord, jogged to its tick, with nothing to restore")
    func afterTheLastChord() {
        let c = Self.chord
        #expect(Self.splice([(Self.at(4), Self.forte)]) == [c, c, c, c, Self.forte])
        let late = Fraction(numerator: 7, denominator: 8)
        #expect(Self.splice([(late, Self.forte)]) == [c, c, c, c, Self.shift(-1, 8), Self.forte])
    }

    @Test("a stop inside a chord and a start at the next beat chain their jogs (testWedgeOffset)")
    func spliceChainsShifts() {
        let c = Self.chord
        let stop = Fraction(numerator: 5, denominator: 8)
        let result = Self.splice([(stop, Self.forte), (Self.at(3), Self.piano)])
        #expect(result == [c, c, c, Self.shift(-1, 8), Self.forte, Self.shift(1, 8), Self.piano, c])
    }

    @Test("an earlier tick goes first however it was queued")
    func earlierTickFirst() {
        let c = Self.chord
        let result = Self.splice([(Self.at(1), Self.piano), (Self.at(0), Self.forte)])
        #expect(result == [Self.forte, c, Self.piano, c, c, c])
    }

    @Test("elements on one tick keep their queue order")
    func sameTickKeepsOrder() {
        let c = Self.chord
        let result = Self.splice([(Self.at(1), Self.forte), (Self.at(1), Self.piano)])
        #expect(result == [c, Self.forte, Self.piano, c, c, c])
    }

    @Test("untimed elements before a chord stay before the inserted one")
    func untimedStayFirst() {
        let clef = VoiceElement.clef(Clef(concertClefType: "G"))
        let anchors = [
            MusicXMLChordAnchor(elementIndex: 1, start: Self.at(0), end: Self.at(1)),
            MusicXMLChordAnchor(elementIndex: 2, start: Self.at(1), end: Self.at(2)),
        ]
        let result = MusicXMLDirectionSplicer.splice(
            [MusicXMLQueuedElement(tick: Self.at(0), element: Self.forte)],
            into: [clef, Self.chord, Self.chord], anchors: anchors,
        )
        #expect(result == [clef, Self.forte, Self.chord, Self.chord])
    }

    @Test("a voice with no chords gets a jog to the tick")
    func noChords() {
        let result = MusicXMLDirectionSplicer.splice(
            [MusicXMLQueuedElement(tick: Self.at(1), element: Self.forte)], into: [], anchors: [],
        )
        #expect(result == [Self.shift(1, 4), Self.forte])
    }
}
