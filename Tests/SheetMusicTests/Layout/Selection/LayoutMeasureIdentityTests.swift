@testable import SheetMusicCore
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

@Suite("Measure-addressed engraved elements")
struct LayoutMeasureIdentityTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static func chord(_ duration: NoteDuration = .half) -> VoiceElement {
        .chord(Chord(duration: duration, notes: [Note(pitch: 60, tpc: 14)]))
    }

    private static func score(_ elements: [VoiceElement]) -> Score {
        let plain = Measure(voices: [Voice(elements: [chord(.whole)])])
        let staff = Staff(measures: [plain, Measure(voices: [Voice(elements: elements)])])
        return ScoreEditor(score: Score(division: 480, parts: [
            Part(id: "a", instrument: Instrument(id: "a"), staves: [staff]),
            Part(id: "b", instrument: Instrument(id: "b"), staves: [staff]),
        ])).score
    }

    @available(macOS 15.0, iOS 16.0, *)
    private static func elements(_ score: Score) -> [LayoutElement] {
        LayoutEngine.layout(score: ScoreEditor(score: score).score, options: .init(), availableWidth: 1000)
            .systems.flatMap(\.measures).filter { $0.measureIndex == 1 }
            .flatMap { $0.elements + $0.invisibleElements }
    }

    @Test("Key identity names the bar shared by pitched staves, excluding mid-bar changes")
    func keyCommandAddress() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var score = Self.score([
            .keySignature(KeySignature(concertKey: 2)), Self.chord(),
            .keySignature(KeySignature(concertKey: 3)), Self.chord(),
        ])
        let keys = Self.elements(score).filter { if case .keySignature = $0 { true } else { false } }
        #expect(keys.count == 4)
        #expect(keys.compactMap(\.elementID) == Array(repeating: .keySignature(measureIndex: 1), count: 2))
        #expect(keys.filter { $0.elementID == nil }.count == 2)
        let index = try #require(keys.compactMap(\.elementID).first?.measureIndexIfAddressedByBar)
        let command = SetKeySignature(measureIndex: index, concertKey: -2)
        #expect(command.measureIndex == 1)
        score = ScoreEditor(score: score).score
        _ = try command.apply(to: &score)
        for part in score.parts {
            let elements = part.staves[0].measures[1].voices[0].elements
            #expect(elements[0] == .keySignature(KeySignature(concertKey: -2)))
            #expect(elements[2] == .keySignature(KeySignature(concertKey: 3)))
        }
        for key in keys {
            #expect(LayoutEngine.translate(element: key, dy: 17).elementID == key.elementID)
        }
    }

    @Test("Keys outside voice zero and on unpitched staves have no command identity")
    func keyEligibility() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let key = VoiceElement.keySignature(KeySignature(concertKey: 2))
        var score = Self.score([key, Self.chord(.whole)])
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.group = "percussion"
            }
        }
        score.parts.updateValue(at: 1) { $0.instrument.useDrumset = true }
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[1].voices.append(Voice(elements: [key, Self.chord(.whole)]))
            }
        }
        let keys = Self.elements(score).filter { if case .keySignature = $0 { true } else { false } }
        #expect(!keys.isEmpty)
        let allMatch1 = keys.allSatisfy { $0.elementID == nil }
        #expect(allMatch1)
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.group = "pitched"
            }
        }
        let pitchedKeys = Self.elements(score).filter { if case .keySignature = $0 { true } else { false } }
        #expect(pitchedKeys.compactMap(\.elementID) == [.keySignature(measureIndex: 1)])
    }

    @Test("A zero-tick non-signature ends the key command's leading run")
    func keyAfterVoltaIsNotLeading() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let score = Self.score([
            .spanner(Spanner(kind: .volta, rawType: "Volta", nextMeasuresOffset: 1)),
            .keySignature(KeySignature(concertKey: 2)), Self.chord(.whole),
        ])
        let keys = Self.elements(score).filter { if case .keySignature = $0 { true } else { false } }
        #expect(keys.count == 2)
        let allMatch2 = keys.allSatisfy { $0.elementID == nil }
        #expect(allMatch2)
    }

    @Test("A system-head key restatement does not acquire a new measure identity")
    func keyRestatement() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var score = Self.score([Self.chord(.whole)])
        for partIndex in score.parts.indices {
            score.parts.updateValue(at: partIndex) { part in
                part.staves.updateValue(at: 0) { staff in
                    var elements = staff.measures[0].voices[0].elements.values
                    elements.insert(
                        .keySignature(KeySignature(concertKey: 2)), at: 0,
                    )
                    staff.measures[0].voices[0].elements = IdentifiedArray(elements)
                }
            }
            score.parts.updateValue(at: partIndex) { part in
                part.staves.updateValue(at: 0) { staff in
                    staff.measures[0].lineBreak = true
                }
            }
        }
        let doc = LayoutEngine.layout(score: ScoreEditor(score: score).score, options: .init(), availableWidth: 1000)
        #expect(doc.systems.count == 2)
        let keys = doc.systems[1].measures.flatMap(\.elements).filter {
            if case .keySignature = $0 { true } else { false }
        }
        #expect(keys.count == 2)
        let allMatch3 = keys.allSatisfy { $0.elementID == nil }
        #expect(allMatch3)
    }

    @Test("Time declarations after notes in any voice name the bar the command re-bars", arguments: [0, 1])
    func timeCommandAddress(voiceIndex: Int) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var score = Self.score([
            Self.chord(), .timeSignature(TimeSignature(numerator: 4, denominator: 4)), Self.chord(),
        ])
        if voiceIndex == 1 {
            for partIndex in score.parts.indices {
                score.parts.updateValue(at: partIndex) { part in
                    part.staves.updateValue(at: 0) { staff in
                        staff.measures[1].voices.insert(
                            Voice(elements: [Self.chord(.whole)]), at: 0,
                        )
                    }
                }
            }
        }
        let meters = Self.elements(score).filter { if case .timeSignature = $0 { true } else { false } }
        #expect(meters.map(\.elementID) == Array(repeating: .timeSignature(measureIndex: 1), count: 2))
        let index = try #require(meters.first?.elementID?.measureIndexIfAddressedByBar)
        let command = SetTimeSignature(measureIndex: index, numerator: 2, denominator: 4)
        #expect(command.measureIndex == 1)
        score = ScoreEditor(score: score).score
        _ = try command.apply(to: &score)
        let allMatch4 = score.parts.allSatisfy { $0.staves[0].measures.count == 3 }
        #expect(allMatch4)
        #expect(TimeSignatureRegion.explicitSignature(in: score, measureIndex: 1)?.numerator == 2)
        for meter in meters {
            #expect(LayoutEngine.translate(element: meter, dy: 17).elementID == meter.elementID)
        }
    }

    @Test("Only the last explicit bar after voice zero's last timed element is addressable")
    func explicitBarCommandAddress() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var score = Self.score([
            Self.chord(), .barLine(BarLine(subtype: "dashed")), Self.chord(),
            .barLine(BarLine(subtype: "double")), .barLine(BarLine(subtype: "end")),
        ])
        score.parts.updateValue(at: 1) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[1].voices.append(Voice(elements: [
                    Self.chord(.whole), .barLine(BarLine(subtype: "dotted")),
                ]))
            }
        }
        let bars = Self.elements(score).filter { if case .barLine = $0 { true } else { false } }
        let expected = ScoreElementID.barLine(measureIndex: 1, role: .explicit)
        #expect(bars.count == 7)
        #expect(bars.compactMap(\.elementID) == [expected, expected])
        #expect(bars.filter { $0.elementID == nil }.count == 5)
        let index = try #require(bars.compactMap(\.elementID).first?.measureIndexIfAddressedByBar)
        let command = SetBarLine(at: MeasureRef(measureIndex: index), style: .double)
        #expect(command.measure.measureIndex == 1)
        score = ScoreEditor(score: score).score
        _ = try command.apply(to: &score)
        for part in score.parts {
            let elements = part.staves[0].measures[1].voices[0].elements
            #expect(elements[1] == .barLine(BarLine(subtype: "dashed")))
            #expect(elements[3] == .barLine(BarLine(subtype: "double")))
            #expect(elements[4] == .barLine(BarLine(subtype: "double")))
        }
        for bar in bars {
            #expect(LayoutEngine.translate(element: bar, dy: 17).elementID == bar.elementID)
        }
    }

    @Test("Synthesized start and trailing repeats retain roles while commands own different properties")
    func synthesizedBarCommandAddresses() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var score = Self.score([Self.chord(.whole)])
        let initial = Self.elements(score).compactMap(\.elementID)
        #expect(initial == Array(repeating: .barLine(measureIndex: 1, role: .trailing), count: 2))
        let index = try #require(initial.first?.measureIndexIfAddressedByBar)
        let repeats = SetRepeatBarLines(at: MeasureRef(measureIndex: index), startRepeat: true, endRepeatCount: 3)
        #expect(repeats.measure.measureIndex == 1)
        _ = try repeats.apply(to: &score)
        let bars = Self.elements(score).filter { if case .barLine = $0 { true } else { false } }
        #expect(bars.compactMap(\.elementID).filter {
            $0 == .barLine(measureIndex: 1, role: .startRepeat)
        }.count == 2)
        #expect(bars.compactMap(\.elementID).filter {
            $0 == .barLine(measureIndex: 1, role: .trailing)
        }.count == 2)
        let start = try #require(bars.first { $0.elementID == .barLine(measureIndex: 1, role: .startRepeat) })
        let startIndex = try #require(start.elementID?.measureIndexIfAddressedByBar)
        let clearStart = SetRepeatBarLines(
            at: MeasureRef(measureIndex: startIndex), startRepeat: false, endRepeatCount: 3,
        )
        #expect(clearStart.measure == repeats.measure)
        _ = try clearStart.apply(to: &score)
        #expect(!score.parts[0].staves[0].measures[1].startRepeat)
        _ = try repeats.apply(to: &score)
        let style = SetBarLine(at: MeasureRef(measureIndex: index), style: .double)
        #expect(style.measure == repeats.measure)
        _ = try style.apply(to: &score)
        #expect(score.parts[0].staves[0].measures[1].endRepeatCount == 3)
        #expect(score.parts[0].staves[0].measures[1].startRepeat)
        #expect(Self.elements(score).compactMap(\.elementID).filter {
            $0 == .barLine(measureIndex: 1, role: .explicit)
        }.count == 2)
    }
}

extension LayoutMeasureIdentityTests {
    @Test("Navigation lists keep independent indices and coincident engraving")
    func navigationListIndices() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let score = Self.navigationScore()
        let measure = try Self.navigationMeasure(score, index: 2)
        try #require(measure.markers.count == 2)
        try #require(measure.jumps.count == 2)
        let owner = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        #expect(measure.markers.map(\.elementID) == [
            .marker(staff: owner, measureIndex: 2, index: 0),
            .marker(staff: owner, measureIndex: 2, index: 1),
        ])
        #expect(measure.jumps.map(\.elementID) == [
            .jump(staff: owner, measureIndex: 2, index: 0),
            .jump(staff: owner, measureIndex: 2, index: 1),
        ])
        let marker = try #require(measure.markers.first)
        let jump = try #require(measure.jumps.first)
        guard case let .marker(_, _, markerOrigin, _) = marker,
              case let .jump(_, jumpOrigin, _) = jump
        else {
            Issue.record("Expected navigation elements")
            return
        }
        // Default sp = 7. Markers use x = 4; jumps use width - 4 sp = width - 28.
        // Their Y gap is the five-line band plus two margins: (4 + 1 + 1) * 7 = 42.
        #expect(markerOrigin.x == 4)
        #expect(jumpOrigin.x == measure.width - 28)
        #expect(jumpOrigin.y - markerOrigin.y == 42)
        #expect(measure.markers[1] == .marker(
            kind: .coda, text: "A coda", origin: markerOrigin,
            identity: .marker(staff: owner, measureIndex: 2, index: 1),
        ))
        #expect(measure.jumps[1] == .jump(
            text: "A jump", origin: jumpOrigin,
            identity: .jump(staff: owner, measureIndex: 2, index: 1),
        ))
        for element in measure.markers + measure.jumps {
            #expect(element.elementItemID == element.elementID.map(ScoreItemID.element))
            let translated = LayoutEngine.translate(element: element, dy: 17)
            #expect(translated.elementID == element.elementID)
            #expect(LayoutEngine.elementYPoints(translated) == LayoutEngine.elementYPoints(element).map { $0 + 17 })
            #expect(LayoutEngine.translate(element: translated, dy: -17) == element)
        }
    }

    @Test("Hiding either staff preserves the drawn owner's navigation and remaps both directions", arguments: [0, 1])
    func filteredNavigationOwner(hiddenIndex: Int) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let full = Self.navigationScore(measureIndex: 0)
        let hidden: Set<StaffAddress> = [StaffAddress(partIndex: 0, staffIndexInPart: hiddenIndex)]
        let filtered = ScoreEditor(score: full.filtered(hidingStaves: hidden)).score
        let measure = try Self.navigationMeasure(filtered, index: 0)
        try #require(measure.markers.count == 2)
        try #require(measure.jumps.count == 2)
        let filteredOwner = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let fullOwner = StaffAddress(partIndex: 0, staffIndexInPart: 1 - hiddenIndex)
        let expected: [ScoreElementID] = [
            .marker(staff: filteredOwner, measureIndex: 0, index: 0),
            .marker(staff: filteredOwner, measureIndex: 0, index: 1),
            .jump(staff: filteredOwner, measureIndex: 0, index: 0),
            .jump(staff: filteredOwner, measureIndex: 0, index: 1),
        ]
        let remapped: [ScoreElementID] = [
            .marker(staff: fullOwner, measureIndex: 0, index: 0),
            .marker(staff: fullOwner, measureIndex: 0, index: 1),
            .jump(staff: fullOwner, measureIndex: 0, index: 0),
            .jump(staff: fullOwner, measureIndex: 0, index: 1),
        ]
        #expect((measure.markers + measure.jumps).compactMap(\.elementID) == expected)
        for (layoutID, fullID) in zip(expected, remapped) {
            let cursor = ScoreCursor.item(.element(layoutID))
            let engine = full.engineCursorForFilteredTap(cursor, hiddenStaves: hidden)
            #expect(engine == .item(.element(fullID)))
            #expect(full.translateCursorForHiddenStaves(engine, hiddenStaves: hidden) == cursor)
        }
        // A separately built one-staff score has identical labels and geometry to the filtered score.
        let reference = ScoreEditor(score: Score(division: 480, parts: [
            Part(id: "navigation", instrument: Instrument(id: "x"), staves: [
                full.parts[0].staves[1 - hiddenIndex],
            ]),
        ])).score
        let single = try Self.navigationMeasure(reference, index: 0)
        #expect(measure.markers == single.markers)
        #expect(measure.jumps == single.jumps)
        guard case let .marker(_, label, _, _) = measure.markers[0] else {
            Issue.record("Expected a marker")
            return
        }
        #expect(label == (hiddenIndex == 0 ? "B segno" : "A segno"))
    }

    @Test("An empty first part does not become the navigation owner")
    func navigationAfterEmptyPart() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var fixture = Self.navigationScore(measureIndex: 0)
        // The fixture is already assigned by one editor's actor; minting from any other actor keeps
        // the new part's identifier from colliding with it.
        var ids = EIDAllocator(actor: fixture.parts.eid(at: 0).first == 42 ? 43 : 42)
        fixture.parts.insert(Part(id: "empty", instrument: Instrument(id: "x"), staves: []), at: 0, id: ids.next())
        let score = ScoreEditor(score: fixture).score
        let measure = try Self.navigationMeasure(score, index: 0)
        let owner = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        #expect(measure.markers.map(\.elementID) == [
            .marker(staff: owner, measureIndex: 0, index: 0),
            .marker(staff: owner, measureIndex: 0, index: 1),
        ])
        #expect(measure.jumps.map(\.elementID) == [
            .jump(staff: owner, measureIndex: 0, index: 0),
            .jump(staff: owner, measureIndex: 0, index: 1),
        ])
    }

    @Test("Empty text and other markers retain list slots; hand-built navigation may have no address")
    func emptyNavigationEntries() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var fixture = Self.navigationScore(measureIndex: 0)
        fixture.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[0].markers[0] = Marker(kind: .other)
            }
        }
        let score = ScoreEditor(score: fixture).score
        let measure = try Self.navigationMeasure(score, index: 0)
        let owner = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        try #require(measure.markers.count == 2)
        try #require(measure.jumps.count == 2)
        #expect(measure.markers[0].elementID == .marker(staff: owner, measureIndex: 0, index: 0))
        #expect(measure.jumps[0].elementID == .jump(staff: owner, measureIndex: 0, index: 0))
        let unaddressed: [LayoutElement] = [
            .marker(kind: .segno, text: "", origin: .zero), .jump(text: "", origin: .zero),
        ]
        #expect(unaddressed.allSatisfy { $0.elementID == nil && $0.elementItemID == nil })
    }

    private static func navigationScore(measureIndex: Int = 2) -> Score {
        let staves: [Staff] = ["A", "B"].map { label in
            var measures = (0 ... measureIndex).map { _ in
                Measure(voices: [Voice(elements: [chord(.whole)])])
            }
            measures[measureIndex].markers = [
                Marker(kind: .segno, label: "\(label) segno"),
                Marker(kind: .coda, label: "unused", text: "\(label) coda"),
            ]
            measures[measureIndex].jumps = [
                Jump(jumpTo: "start", playUntil: "end"),
                Jump(jumpTo: "segno", playUntil: "end", text: "\(label) jump"),
            ]
            return Staff(measures: measures)
        }
        return ScoreEditor(score: Score(division: 480, parts: [
            Part(id: "navigation", instrument: Instrument(id: "x"), staves: IdentifiedArray(staves)),
        ])).score
    }

    @available(macOS 15.0, iOS 16.0, *)
    private static func navigationMeasure(_ score: Score, index: Int) throws -> LayoutMeasure {
        let document = LayoutEngine.layout(
            score: score, options: .init(wrapToViewWidth: false), availableWidth: 1000,
        )
        return try #require(document.systems.flatMap(\.measures).first { $0.measureIndex == index })
    }
}
