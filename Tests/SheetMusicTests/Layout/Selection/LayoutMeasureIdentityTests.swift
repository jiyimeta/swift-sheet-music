@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("Measure-addressed engraved elements")
struct LayoutMeasureIdentityTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static func chord(_ duration: NoteDuration = .half) -> VoiceElement {
        .chord(Chord(duration: duration, notes: [Note(pitch: 60, tpc: 14)]))
    }

    private static func score(_ elements: [VoiceElement]) -> Score {
        let plain = Measure(voices: [Voice(elements: [chord(.whole)])])
        let staff = Staff(measures: [plain, Measure(voices: [Voice(elements: elements)])])
        return Score(division: 480, parts: [
            Part(id: "a", instrument: Instrument(id: "a"), staves: [staff]),
            Part(id: "b", instrument: Instrument(id: "b"), staves: [staff]),
        ])
    }

    @available(macOS 15.0, iOS 16.0, *)
    private static func elements(_ score: Score) -> [LayoutElement] {
        LayoutEngine.layout(score: score, options: .init(), availableWidth: 1000)
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
        let doc = LayoutEngine.layout(score: score, options: .init(), availableWidth: 1000)
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
