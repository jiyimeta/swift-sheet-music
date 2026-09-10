@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("Engraved element command addresses")
struct LayoutElementIdentityTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static let staff = StaffAddress(partIndex: 1, staffIndexInPart: 1)

    private static func address(_ index: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: 1, voiceIndex: 1, elementIndex: index)
    }

    private static func chord(_ duration: NoteDuration = .quarter) -> VoiceElement {
        .chord(Chord(duration: duration, notes: [Note(pitch: 60, tpc: 14)]))
    }

    private static func score(_ elements: [VoiceElement]) -> Score {
        let plain = Measure(voices: [Voice(elements: [chord(.whole)])])
        let staff = Staff(measures: [plain, plain])
        var score = Score(division: 480, parts: [
            Part(id: "a", instrument: Instrument(id: "a"), staves: [staff]),
            Part(id: "b", instrument: Instrument(id: "b"), staves: [staff, staff]),
        ])
        score.parts.updateValue(at: 1) { part in
            part.staves.updateValue(at: 1) { staff in
                staff.measures[1].voices.append(Voice(elements: elements))
            }
        }
        return score
    }

    @available(macOS 15.0, iOS 16.0, *)
    private static func elements(_ score: Score) -> [LayoutElement] {
        LayoutEngine.layout(score: score, options: .init(), availableWidth: 1000)
            .systems.flatMap { system in
                system.measures.flatMap { $0.elements + $0.invisibleElements } + system.spanners
            }
            .filter {
                // These tests cover owner-anchored markings; measure identities have their own suite.
                switch $0 {
                case .keySignature, .timeSignature, .barLine: false
                default: true
                }
            }
    }

    @Test("Adjacent markings name the chord the commands accept, not their own slots")
    func adjacentCommandAddresses() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        // Slots: rest 0, dynamic 1, fermata 2, chord 3, breath 4, chord 5.
        // The leading rest distinguishes the owner from the beat-zero element.
        var score = Self.score([
            .rest(duration: .quarter), .dynamic(Dynamic(subtype: "mf", velocity: 80)),
            .fermata(Fermata(subtype: "fermataAbove")), Self.chord(),
            .breath(Breath(kind: .breathMark(.comma), pause: 0)), Self.chord(.half),
        ])
        let expected = Self.address(3)
        let ids = Self.elements(score).compactMap(\.elementID)
        #expect(ids == [.dynamic(anchor: expected), .fermata(anchor: expected), .breath(anchor: expected)])
        let dynamic = SetDynamic(at: expected, subtype: "ff")
        let fermata = SetFermata(at: expected, subtype: "fermataLongAbove", timeStretch: 2)
        let breath = SetBreath(after: expected, kind: .caesura(.normal), pause: 0)
        #expect(ids.map(\.anchor) == [dynamic.location, fermata.location, breath.location])
        _ = try dynamic.apply(to: &score)
        _ = try fermata.apply(to: &score)
        _ = try breath.apply(to: &score)
        #expect(SetDynamic.current(at: expected, in: score)?.subtype == "ff")
        #expect(SetFermata.current(at: expected, in: score)?.subtype == "fermataLongAbove")
        #expect(SetBreath.current(after: expected, in: score)?.kind == .caesura(.normal))
        #expect(Self.elements(score).compactMap(\.elementID) == ids)
    }

    @Test("Fermata accepts a rest, while dynamic and breath require notes")
    func restEligibility() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let score = Self.score([
            .dynamic(Dynamic(subtype: "p", velocity: 49)),
            .fermata(Fermata(subtype: "fermataAbove")), .rest(duration: .whole),
            .breath(Breath(kind: .breathMark(.comma), pause: 0)),
        ])
        #expect(Self.elements(score).compactMap(\.elementID) == [.fermata(anchor: Self.address(2))])
    }

    @Test("Attachment boundaries cannot be crossed to find a visually nearby owner")
    func attachmentBoundaries() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let score = Self.score([
            .dynamic(Dynamic(subtype: "p", velocity: 49)),
            .locationShift(delta: Fraction(numerator: 0, denominator: 1)),
            .fermata(Fermata(subtype: "fermataAbove")), .barLine(BarLine(subtype: "normal")),
            Self.chord(.whole), .locationShift(delta: Fraction(numerator: 0, denominator: 1)),
            .breath(Breath(kind: .breathMark(.comma), pause: 0)),
        ])
        #expect(Self.elements(score).compactMap(\.elementID).isEmpty)
    }

    @Test("Duplicate markings share the command's attachment-run address")
    func duplicateRun() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let score = Self.score([
            .dynamic(Dynamic(subtype: "p", velocity: 49)),
            .dynamic(Dynamic(subtype: "f", velocity: 96)), Self.chord(.whole),
            .breath(Breath(kind: .breathMark(.comma), pause: 0)),
            .breath(Breath(kind: .caesura(.normal), pause: 0)),
        ])
        let expected = Self.address(2)
        #expect(Self.elements(score).compactMap(\.elementID) == [
            .dynamic(anchor: expected), .dynamic(anchor: expected),
            .breath(anchor: expected), .breath(anchor: expected),
        ])
    }

    @Test("Layout's attachment walk agrees with the command's run across annotations and signatures")
    func attachmentRunParity() {
        let separators: [VoiceElement] = [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .sticking(Sticking(text: "R")), .expression(ExpressionText(text: "dolce")),
            .capo(Capo(text: "")), .stringTunings(StringTunings()),
            .barLine(BarLine(subtype: "normal")),
            .locationShift(delta: Fraction(numerator: 0, denominator: 1)),
        ]
        for separator in separators {
            let voice = Voice(elements: [
                .dynamic(Dynamic(subtype: "p", velocity: 49)), separator, Self.chord(),
            ])
            let run = AdjacentElementSlot.run(.before, of: 2, in: voice.elements.values)
            let expected = run.contains(0) ? Self.address(2) : nil
            #expect(LayoutEngine.attachmentAnchor(at: Self.address(0), in: voice) == expected)
        }
    }

    @Test("Tempo reuses the first voice with an onset at the lane's tick")
    func tempoCommandAddress() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var score = Self.score([Self.chord(), Self.chord(), Self.chord(.half)])
        // Voice 0 has only a whole chord at tick 0. At tick 480 the lane must name voice 1, slot 1.
        let expected = Self.address(1)
        let command = SetTempo(anchor: expected, marking: .init(beatsPerSecond: 3))
        _ = try command.apply(to: &score)
        // System marks default to the canonical staff; put this imported mark on the fixture's staff.
        score.systemMeasures.updateValue(at: 1) {
            $0.elements.updateValue(at: 0) { $0.originalStaff = Self.staff }
        }
        let tempos = Self.elements(score).filter { if case .textMark(.tempo, _, _) = $0 { true } else { false } }
        #expect(tempos.map(\.elementID) == [.tempo(anchor: command.anchor)])
        #expect(tempos.map(\.elementItemID) == [.element(.tempo(anchor: expected))])
        let id = try #require(tempos.first?.elementID?.anchor)
        _ = try SetTempo(anchor: id, marking: .init(beatsPerSecond: 4)).apply(to: &score)
        #expect(SetTempo.current(at: expected, in: score)?.beatsPerSecond == 4)
    }

    @Test("An off-onset tempo has no command address")
    func unanchoredTempo() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var score = Self.score([Self.chord(.whole)])
        score.systemMeasures = [SystemMeasure(), SystemMeasure(elements: [
            PositionedSystemElement(
                position: .init(numerator: 1, denominator: 8),
                element: .tempo(Tempo(beatsPerSecond: 2)), originalStaff: Self.staff,
            ),
        ])]
        let tempos = Self.elements(score).filter { if case .textMark(.tempo, _, _) = $0 { true } else { false } }
        #expect(tempos.count == 1)
        #expect(tempos.first?.elementID == nil)
    }

    @Test("Articulation retains its chord address and model kind through beam replacement")
    func articulationCommandAddress() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var score = Self.score([Self.chord(.eighth), Self.chord(.eighth), Self.chord(.half)])
        let expected = Self.address(1)
        let kinds: [ChordArticulation.Kind] = [
            .staccato, .staccatissimo, .tenuto, .accent, .marcato, .accentStaccato, .marcatoStaccato,
        ]
        for kind in kinds {
            _ = try SetArticulation(at: expected, kind: kind, anchor: nil, present: true).apply(to: &score)
        }
        let elements = Self.elements(score)
        let beamed = elements.filter {
            if case .chord(_, _, _, _, _, _, true, 1, _, _, _) = $0 { true } else { false }
        }
        #expect(beamed.count == 2)
        let ids = elements.compactMap(\.elementID)
        #expect(ids == kinds.map { .articulation(anchor: expected, kind: $0) })
        for id in ids {
            guard case let .articulation(anchor, kind) = id else { Issue.record("Expected articulation"); continue }
            let command = SetArticulation(at: anchor, kind: kind, anchor: nil, present: false)
            #expect(command.location == expected)
            _ = try command.apply(to: &score)
        }
        #expect(Self.elements(score).compactMap(\.elementID).isEmpty)
    }
}
