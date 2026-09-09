import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("Spanner segment command identity")
struct LayoutSpannerIdentityTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static let anchor = VoiceElementID(
        staff: StaffAddress(partIndex: 1, staffIndexInPart: 1),
        measureIndex: 1, voiceIndex: 1, elementIndex: 1,
    )

    private static func score(kind: Spanner.Kind) -> Score {
        let chord = VoiceElement.chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)]))
        let plain = Measure(voices: [Voice(elements: [chord])], lineBreak: true)
        let staff = Staff(measures: Array(repeating: plain, count: 4))
        var score = Score(division: 480, parts: [
            Part(id: "a", instrument: Instrument(id: "a"), staves: [staff]),
            Part(id: "b", instrument: Instrument(id: "b"), staves: [staff, staff]),
        ])
        // Starts at tick 480 in measure 1, voice 1, slot 1. Two measure offsets plus
        // a quarter-note offset end at tick 960 in measure 3, crossing the middle system.
        score.parts[1].staves[1].measures[1].voices.append(Voice(elements: [
            .rest(duration: .quarter),
            .spanner(Spanner(
                kind: kind,
                rawType: "",
                nextMeasuresOffset: 2,
                nextFractionsOffset: Fraction(numerator: 1, denominator: 4),
            )),
            .chord(Chord(duration: .half.dotted(1), notes: [Note(pitch: 60, tpc: 14)])),
        ]))
        return score
    }

    @Test(
        "Every clipped segment names the source slot accepted by RemoveSpanner",
        arguments: [Spanner.Kind.hairpin, .pedal, .ottava, .volta],
    )
    func commandAddress(kind: Spanner.Kind) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var score = Self.score(kind: kind)
        let collected = try #require(LayoutEngine.collectSpanners(score: score).first)
        #expect(collected.startStaff == 2)
        #expect(collected.staffAddress == Self.anchor.staff)
        #expect(collected.startMeasure == 1)
        #expect(collected.voiceIndex == 1)
        #expect(collected.elementIndex == 1)
        #expect(collected.startTick == 480)
        #expect(collected.endMeasure == 3)
        #expect(collected.endTick == 960)
        let doc = LayoutEngine.layout(score: score, options: .init(), availableWidth: 1000)
        #expect(doc.systems.map { $0.measures.map(\.measureIndex) } == [[0], [1], [2], [3]])
        let segments = doc.systems.flatMap(\.spanners).filter {
            if case .spannerSegment = $0 { true } else { false }
        }
        let expected = ScoreElementID.spanner(anchor: Self.anchor, kind: kind)
        #expect(segments.map(\.elementID) == [expected, expected, expected])
        #expect(segments.map(\.elementItemID) == Array(repeating: .element(expected), count: 3))
        for (index, segment) in segments.enumerated() {
            guard case let .spannerSegment(_, _, _, left, right, _, _) = segment else { continue }
            #expect(left == (index > 0))
            #expect(right == (index < 2))
            #expect(LayoutEngine.translate(element: segment, dy: 17).elementID == expected)
        }
        let id = try #require(segments.first?.elementID)
        guard case let .spanner(anchor, selectedKind) = id else {
            Issue.record("Expected spanner identity")
            return
        }
        let command = RemoveSpanner(at: anchor, kind: selectedKind)
        #expect(command.location == Self.anchor)
        #expect(command.kind == kind)
        _ = try command.apply(to: &score)
        #expect(LayoutEngine.collectSpanners(score: score).isEmpty)
        let removed = LayoutEngine.layout(score: score, options: .init(), availableWidth: 1000)
        #expect(removed.systems.flatMap(\.spanners).compactMap(\.elementID).isEmpty)
    }

    @Test("SetVolta inserts on the canonical staff, but selection follows the slot after a head insertion")
    func voltaInsertionAndCurrentAddress() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var score = Self.score(kind: .volta)
        _ = try RemoveSpanner(at: Self.anchor, kind: .volta).apply(to: &score)
        let range = VoiceElementRange(start: Self.anchor, end: Self.anchor)
        let command = SetVolta(over: range, endings: [1], text: nil)
        _ = try command.apply(to: &score)
        let inserted = VoiceElementID(
            staff: Score.canonicalStaff, measureIndex: 1, voiceIndex: 0, elementIndex: 0,
        )
        #expect(command.affectedLocation == inserted)
        let first = LayoutEngine.layout(score: score, options: .init(), availableWidth: 1000)
        #expect(first.systems.flatMap(\.spanners).compactMap(\.elementID) == [
            .spanner(anchor: inserted, kind: .volta),
        ])
        score.parts[0].staves[0].measures[1].voices[0].elements.insert(
            .keySignature(KeySignature(concertKey: 2)), at: 0,
        )
        let moved = VoiceElementID(
            staff: Score.canonicalStaff, measureIndex: 1, voiceIndex: 0, elementIndex: 1,
        )
        let second = LayoutEngine.layout(score: score, options: .init(), availableWidth: 1000)
        let ids = second.systems.flatMap(\.spanners).compactMap(\.elementID)
        #expect(ids == [.spanner(anchor: moved, kind: .volta)])
        let anchor = try #require(ids.first?.anchor)
        _ = try RemoveSpanner(at: anchor, kind: .volta).apply(to: &score)
        #expect(LayoutEngine.collectSpanners(score: score).isEmpty)
        #expect(score.parts[0].staves[0].measures[1].voices[0].elements[0]
            == .keySignature(KeySignature(concertKey: 2)))
    }

    @Test("Explicitly unanchored geometry never reports a selectable item")
    func absentAnchors() {
        let elements: [LayoutElement] = [
            .textMark(kind: .dynamic(anchor: nil), text: "p", origin: .zero),
            .textMark(kind: .tempo(anchor: nil), text: "120", origin: .zero),
            .fermata(subtype: "fermataAbove", origin: .zero, anchor: nil),
            .breath(kind: .breathMark(.comma), origin: .zero, anchor: nil),
            .articulation(kind: .accent, origin: .zero, isAbove: true, anchor: nil),
            .spannerSegment(
                kind: .hairpinOpen,
                fromOrigin: .zero,
                toOrigin: .zero,
                continuesLeft: false,
                continuesRight: false,
                text: "",
                anchor: nil,
            ),
            .spannerSegment(
                kind: .pedal,
                fromOrigin: .zero,
                toOrigin: .zero,
                continuesLeft: false,
                continuesRight: false,
                text: "",
                anchor: nil,
            ),
            .spannerSegment(
                kind: .ottava(subtype: .eightVA, numbersOnly: false),
                fromOrigin: .zero,
                toOrigin: .zero,
                continuesLeft: false,
                continuesRight: false,
                text: "",
                anchor: nil,
            ),
            .barLine(subtype: "normal", origin: .zero, halfHeight: 14, measureIndex: nil, role: .explicit),
        ]
        #expect(elements.allSatisfy { $0.elementID == nil && $0.elementItemID == nil })
    }
}
