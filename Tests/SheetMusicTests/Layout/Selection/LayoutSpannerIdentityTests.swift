import SheetMusicCore
import SheetMusicFoundation
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// On Android and WebAssembly, SheetMusicCore and SheetMusicLayout both export portable
    /// `CGFloat` / `CGPoint` shims, so anchor explicitly to SheetMusicLayout's definitions.
    ///
    /// `private typealias` keeps these file-scoped — a module-scope alias here would collide
    /// with the same pattern in every other file in this target that needs it.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

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
        return ScoreEditor(score: score).score
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

extension LayoutSpannerIdentityTests {
    private static let slurOwner = VoiceElementID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
        measureIndex: 0, voiceIndex: 0, elementIndex: 0,
    )

    @Test("Slur ordinals include hidden and unresolved entries but exclude other kinds", arguments: [false, true])
    func chordSlurStorageOrdinals(_ firstIsVisible: Bool) {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let score = Self.chordSlurScore(spanners: [
            Spanner(kind: .hairpin, rawType: "HairPin"),
            Spanner(kind: .slur, rawType: "Slur", nextMeasuresOffset: 9, visible: firstIsVisible),
            Self.quarterSlur(),
            Spanner(kind: .pedal, rawType: "Pedal"),
            Self.quarterSlur(),
        ])
        let expected: [SlurID] = [
            .chord(anchor: Self.slurOwner, ordinal: 1),
            .chord(anchor: Self.slurOwner, ordinal: 2),
        ]
        // Slur-only storage positions are 0/1/2; raw array indices are 1/2/4.
        // Entry 0 consumes its ordinal whether hidden or visibly unresolved.
        let collected = LayoutEngine.collectSlurs(score: score)
        #expect(collected.map(\.identity) == expected)
        #expect(collected.map(\.end.elementIndex) == [1, 1])
        let document = LayoutEngine.layout(score: score, options: .init(), availableWidth: 800)
        let pairs = LayoutEngine.resolveSlurs(for: document, score: score)
        #expect(pairs.map(\.identity) == expected.map { .slur($0) })
        let arcs = document.systems.flatMap(\.spanners).filter {
            if case .tieArc = $0 { true } else { false }
        }
        #expect(arcs.map(\.elementID) == expected.map { .slur($0) })
        #expect(arcs.map(\.elementItemID) == expected.map { .element(.slur($0)) })
    }

    @Test("A rest-owned slur keeps the rest slot and reaches the next quarter rest")
    func restSlurIdentity() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let score = Self.chordSlurScore(spanners: [Self.quarterSlur()], rests: true)
        let collected = LayoutEngine.collectSlurs(score: score)
        #expect(collected.count == 1)
        let pairing = try #require(collected.first)
        let expected = ScoreElementID.slur(.chord(anchor: Self.slurOwner, ordinal: 0))
        #expect(pairing.identity == .chord(anchor: Self.slurOwner, ordinal: 0))
        #expect(pairing.start.elementIndex == 0)
        // Fraction 1/4 at division 480 is 1 * 4 * 480 / 4 = 480: the second rest starts at slot 1.
        #expect(pairing.end.measureIndex == 0)
        #expect(pairing.end.elementIndex == 1)
        let document = LayoutEngine.layout(score: score, options: .init(), availableWidth: 800)
        let pairs = LayoutEngine.resolveSlurs(for: document, score: score)
        #expect(pairs.map(\.identity) == [expected])
        #expect(document.systems.flatMap(\.spanners).compactMap(\.elementID) == [expected])
    }

    @Test("A standalone slur names its voice slot on every emitted segment", arguments: [false, true])
    func standaloneSlurIdentity(_ split: Bool) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let score = Self.standaloneSlurScore()
        let anchors = LayoutEngine.collectSpanners(score: score)
        #expect(anchors.count == 1)
        let anchor = try #require(anchors.first)
        let owner = VoiceElementID(
            staff: Self.slurOwner.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2,
        )
        #expect(anchor.selectionAnchor == owner)
        #expect(anchor.startTick == 960) // Two quarters before slot 2: 2 * 480.
        #expect(anchor.endMeasure == 1)
        #expect(anchor.endTick == 1440) // Same tick in next measure plus a quarter: 960 + 480.
        let first = Self.segmentMeasure(0)
        let second = Self.segmentMeasure(1)
        let systems = split
            ? [Self.segmentSystem([first], y: 0), Self.segmentSystem([second], y: 100)]
            : [Self.segmentSystem([first, second], y: 0)]
        let attached = LayoutEngine.attachSpanners(
            to: systems, anchors: anchors, score: score, metrics: StaffMetrics(staffSize: 40),
        )
        let expected = ScoreElementID.slur(.voice(owner))
        let segments = attached.flatMap(\.spanners)
        #expect(segments.count == (split ? 2 : 1))
        #expect(segments.map(\.elementID) == Array(repeating: expected, count: split ? 2 : 1))
        for (index, segment) in segments.enumerated() {
            guard case let .spannerSegment(kind, _, _, left, right, _, slot) = segment else {
                Issue.record("Expected a standalone slur segment")
                continue
            }
            #expect(kind == .slur)
            #expect(slot == owner)
            #expect(left == (split && index == 1))
            #expect(right == (split && index == 0))
            #expect(segment.elementID != .spanner(anchor: owner, kind: .slur))
            #expect(segment.elementItemID == .element(expected))
            #expect(LayoutEngine.translate(element: segment, dy: 17).elementID == expected)
        }
    }

    @Test("Other unsupported spanner kinds remain unaddressed", arguments: [
        Spanner.Kind.vibrato, .trill, .textLine, .palmMute, .letRing,
    ])
    func unsupportedSpannersRemainUnaddressed(_ kind: Spanner.Kind) throws {
        let score = Self.score(kind: kind)
        let anchor = try #require(LayoutEngine.collectSpanners(score: score).first)
        #expect(anchor.selectionAnchor == nil)
        let segment = LayoutElement.spannerSegment(
            kind: LayoutEngine.layoutKind(anchor: anchor), fromOrigin: .zero, toOrigin: .zero,
            continuesLeft: false, continuesRight: false, text: "", anchor: Self.anchor,
        )
        #expect(segment.elementID == nil)
        #expect(segment.elementItemID == nil)
    }

    @Test("A standalone slur without an anchor remains unselectable")
    func unanchoredStandaloneSlur() {
        let segment = LayoutElement.spannerSegment(
            kind: .slur, fromOrigin: .zero, toOrigin: .zero,
            continuesLeft: false, continuesRight: false, text: "", anchor: nil,
        )
        #expect(segment.elementID == nil)
        #expect(segment.elementItemID == nil)
    }

    private static func quarterSlur() -> Spanner {
        Spanner(
            kind: .slur, rawType: "Slur", nextMeasuresOffset: 0,
            nextFractionsOffset: Fraction(numerator: 1, denominator: 4),
        )
    }

    private static func chordSlurScore(spanners: [Spanner], rests: Bool = false) -> Score {
        let notes: ChordNotes = rests ? [] : [Note(pitch: 79, tpc: 15)]
        return ScoreEditor(score: Score(division: 480, parts: [
            Part(id: "slur", instrument: Instrument(id: "x"), staves: [
                Staff(measures: [Measure(voices: [Voice(elements: [
                    .chord(Chord(duration: .quarter, notes: notes, spanners: spanners)),
                    .chord(Chord(duration: .quarter, notes: notes)),
                ])])]),
            ]),
        ])).score
    }

    private static func standaloneSlurScore() -> Score {
        let start = Measure(voices: [Voice(elements: [
            .rest(duration: .quarter), .rest(duration: .quarter),
            .spanner(Spanner(
                kind: .slur, rawType: "Slur", nextMeasuresOffset: 1,
                nextFractionsOffset: Fraction(numerator: 1, denominator: 4),
            )),
            .chord(Chord(duration: .half, notes: [Note(pitch: 79, tpc: 15)])),
        ])])
        let end = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: [Note(pitch: 79, tpc: 15)])),
        ])])
        return ScoreEditor(score: Score(division: 480, parts: [
            Part(id: "slur", instrument: Instrument(id: "x"), staves: [Staff(measures: [start, end])]),
        ])).score
    }

    private static func segmentMeasure(_ index: Int) -> LayoutMeasure {
        LayoutMeasure(
            measureIndex: index, origin: .zero, width: 100, elements: [],
            tickColumns: [0: 20, 960: 60, 1440: 80],
        )
    }

    private static func segmentSystem(_ measures: [LayoutMeasure], y: CGFloat) -> LayoutSystem {
        LayoutSystem(
            origin: CGPoint(x: 0, y: y), size: .init(width: 100, height: 80), measures: measures,
            staffOrigins: [.zero], staffAddresses: [slurOwner.staff], partLabels: [], spanners: [], sp: 10,
        )
    }
}
