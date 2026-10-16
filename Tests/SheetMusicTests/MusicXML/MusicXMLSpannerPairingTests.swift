import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

/// The `<next>` rule and the slot rules (`P2:3777-3839`), on synthetic events. A bar is eight eighths; there are four.
@Suite("MusicXML spanner pairing")
struct MusicXMLSpannerPairingTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let fromMeasure: Int
        let fromEighth: Int
        let toMeasure: Int
        let toEighth: Int
        let measures: Int?
        let eighths: Int?

        var testDescription: String {
            "(\(fromMeasure), \(fromEighth)/8) → (\(toMeasure), \(toEighth)/8)"
        }
    }

    private static func eighths(_ count: Int) -> Fraction {
        Fraction(numerator: count, denominator: 8)
    }

    private static let bars = Array(repeating: Fraction(numerator: 1, denominator: 1), count: 4)

    private static let rows: [Row] = [
        Row(fromMeasure: 0, fromEighth: 0, toMeasure: 0, toEighth: 4, measures: 0, eighths: 4),
        Row(fromMeasure: 0, fromEighth: 0, toMeasure: 1, toEighth: 0, measures: 1, eighths: nil),
        Row(fromMeasure: 0, fromEighth: 6, toMeasure: 1, toEighth: 0, measures: 1, eighths: -6),
        Row(fromMeasure: 0, fromEighth: 0, toMeasure: 0, toEighth: 8, measures: 1, eighths: nil),
        Row(fromMeasure: 0, fromEighth: 2, toMeasure: 3, toEighth: 8, measures: 3, eighths: 6),
        Row(fromMeasure: 1, fromEighth: 0, toMeasure: 0, toEighth: 4, measures: nil, eighths: nil),
        Row(fromMeasure: 0, fromEighth: 8, toMeasure: 1, toEighth: 4, measures: 0, eighths: 4),
        Row(fromMeasure: 0, fromEighth: 0, toMeasure: 2, toEighth: 12, measures: 3, eighths: 4),
    ]

    @Test(
        "a stop's measure and offset minus the start's, rolling bar ends forward (connectorinfowriter.cpp:82-96)",
        arguments: rows,
    )
    func offsets(_ row: Row) {
        let result = MusicXMLSpannerPairing.offsets(
            fromMeasure: row.fromMeasure, fromTick: Self.eighths(row.fromEighth),
            toMeasure: row.toMeasure, toTick: Self.eighths(row.toEighth), measureLengths: Self.bars,
        )
        let expected = row.eighths.map { Self.eighths($0) }
        #expect(result?.measures == row.measures)
        #expect(result?.fractions == expected)
    }

    private static let slot = MusicXMLSpannerSlot(family: .hairpin, number: 0)
    private static let other = MusicXMLSpannerSlot(family: .hairpin, number: 1)

    private static func start(
        _ slot: MusicXMLSpannerSlot, measure: Int = 0, eighth: Int = 0, type: Int = 0,
    ) -> MusicXMLDirectionEvent {
        let payload = Spanner.HairpinPayload(subtype: type == 0 ? .crescendo : .decrescendo)
        let spanner = Spanner(kind: .hairpin, rawType: "HairPin", hairpin: payload)
        return MusicXMLDirectionEvent(
            measure: measure, staff: 0, tick: eighths(eighth), payload: .spannerStart(slot, spanner),
        )
    }

    private static func stop(_ slot: MusicXMLSpannerSlot, measure: Int = 0, eighth: Int) -> MusicXMLDirectionEvent {
        MusicXMLDirectionEvent(
            measure: measure, staff: 0, tick: eighths(eighth), payload: .spannerStop(slot, MusicXMLSpannerStopEdit()),
        )
    }

    private typealias Found = (measure: Int, eighths: Int, spanner: Spanner)

    private static func spanners(_ events: [MusicXMLDirectionEvent]) -> [Found] {
        events.compactMap { event -> Found? in
            guard case let .voice(.spanner(spanner)) = event.payload else { return nil }
            return (event.measure, event.tick.numerator * 8 / event.tick.denominator, spanner)
        }
    }

    @Test("a start and a stop make a begin side and a payload-less end marker")
    func beginAndEnd() {
        let events = MusicXMLSpannerPairing.pair(
            [Self.start(Self.slot), Self.stop(Self.slot, eighth: 4)], measureLengths: Self.bars,
        )
        let found = Self.spanners(events)
        #expect(found.count == 2)
        let begin = found.first { !$0.spanner.isEndMarker }
        let end = found.first { $0.spanner.isEndMarker }
        #expect(begin?.spanner.nextFractionsOffset == Self.eighths(4))
        #expect(begin?.spanner.hairpin?.subtype == .crescendo)
        #expect(end?.eighths == 4)
        #expect(end?.spanner.rawType == "HairPin")
    }

    @Test("a stop that comes before its start waits for it (P2:3798-3804)")
    func stopBeforeStart() {
        let events = MusicXMLSpannerPairing.pair(
            [Self.stop(Self.slot, eighth: 4), Self.start(Self.slot)], measureLengths: Self.bars,
        )
        #expect(Self.spanners(events).count == 2)
    }

    @Test("a start with no stop is dropped (P2:1853-1865)")
    func unterminated() {
        #expect(MusicXMLSpannerPairing.pair([Self.start(Self.slot)], measureLengths: Self.bars).isEmpty)
    }

    @Test("a second start in an open slot is ignored (P2:3812-3815)")
    func secondStartIgnored() {
        let events = MusicXMLSpannerPairing.pair(
            [
                Self.start(Self.slot, type: 0), Self.start(Self.slot, eighth: 2, type: 1),
                Self.stop(Self.slot, eighth: 4),
            ],
            measureLengths: Self.bars,
        )
        let begins = Self.spanners(events).filter { !$0.spanner.isEndMarker }
        #expect(begins.count == 1)
        #expect(begins.first?.spanner.hairpin?.subtype == .crescendo)
    }

    @Test("slots with different numbers pair independently")
    func independentSlots() {
        let events = MusicXMLSpannerPairing.pair(
            [
                Self.start(Self.slot), Self.start(Self.other, eighth: 2),
                Self.stop(Self.slot, eighth: 6), Self.stop(Self.other, measure: 1, eighth: 0),
            ],
            measureLengths: Self.bars,
        )
        let begins = Self.spanners(events).filter { !$0.spanner.isEndMarker }
        #expect(begins.map(\.spanner.nextFractionsOffset) == [Self.eighths(6), Self.eighths(-2)])
        #expect(begins.map(\.spanner.nextMeasuresOffset) == [0, 1])
    }

    @Test("ends come before begins on one tick")
    func endsFirst() {
        let events = MusicXMLSpannerPairing.pair(
            [
                Self.start(Self.slot), Self.stop(Self.slot, eighth: 4),
                Self.start(Self.other, eighth: 4), Self.stop(Self.other, eighth: 6),
            ],
            measureLengths: Self.bars,
        )
        let atFour = Self.spanners(events).filter { $0.eighths == 4 }
        #expect(atFour.map(\.spanner.isEndMarker) == [true, false])
    }

    @Test("a zero-length spanner keeps its begin before its own end")
    func zeroLength() {
        let events = MusicXMLSpannerPairing.pair(
            [Self.start(Self.slot, eighth: 2), Self.stop(Self.slot, eighth: 2)], measureLengths: Self.bars,
        )
        #expect(Self.spanners(events).map(\.spanner.isEndMarker) == [false, true])
    }
}
