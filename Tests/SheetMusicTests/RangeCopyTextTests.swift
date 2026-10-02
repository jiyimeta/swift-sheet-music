import Foundation
@testable import SheetMusicCore
import SheetMusicMSCX
import Testing

@Suite("Range copy texts")
struct RangeCopyTextTests {
    private static let top = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let middle = StaffAddress(partIndex: 0, staffIndexInPart: 1)
    private static let bottom = StaffAddress(partIndex: 0, staffIndexInPart: 2)

    private static func slot(
        staff: StaffAddress, measure: Int = 0, beat: Int,
    ) -> VoiceElementID {
        VoiceElementID(
            staff: staff, measureIndex: measure, voiceIndex: 0,
            elementIndex: measure == 0 ? beat + 1 : beat,
        )
    }

    private static func score(staffCount: Int = 2, measureCount: Int = 3) -> Score {
        func quarter(_ pitch: Int) -> VoiceElement {
            .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: 14)]))
        }
        let staves = (0 ..< staffCount).map { staffIndex in
            Staff(measures: (0 ..< measureCount).map { measureIndex in
                var elements = (0 ..< 4).map { _ in quarter(60 + staffIndex + measureIndex) }
                if measureIndex == 0 {
                    elements.insert(.timeSignature(TimeSignature(numerator: 4, denominator: 4)), at: 0)
                }
                return Measure(voices: [Voice(elements: elements)])
            })
        }
        return Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "piano"), staves: IdentifiedArray(staves))],
            systemMeasures: IdentifiedArray((0 ..< measureCount).map { _ in SystemMeasure() }),
        )
    }

    private static func text(
        _ value: String, system: Bool = false, color: ScoreColor? = nil, offsetX: Double = 0,
    ) -> StaffText {
        StaffText(text: value, offsetX: offsetX, color: color, isSystemText: system)
    }

    private static func add(
        _ text: StaffText, to score: inout Score, measure: Int = 0, beat: Int,
        staff: StaffAddress?,
    ) {
        score.systemMeasures.updateValue(at: measure) { systemMeasure in
            systemMeasure.elements = IdentifiedArray(systemMeasure.elements.values + [PositionedSystemElement(
                position: MeasurePosition(numerator: beat, denominator: 4),
                element: .staffText(text), originalStaff: staff,
            )])
        }
    }

    private static func texts(in score: Score, measure: Int) -> [PositionedSystemElement] {
        guard score.systemMeasures.indices.contains(measure) else { return [] }
        return score.systemMeasures[measure].elements.filter {
            if case .staffText = $0.element { true } else { false }
        }
    }

    private static func named(
        _ name: String, in score: Score, measure: Int,
    ) -> PositionedSystemElement? {
        texts(in: score, measure: measure).first {
            guard case let .staffText(text) = $0.element else { return false }
            return text.text == name
        }
    }

    @Test("clipboard ranges carry only in-range staff and system texts, rebased onto payload staves")
    func clipboardCarriesAndRebasesTexts() throws {
        var source = Self.score(measureCount: 1)
        Self.add(Self.text("top beat 2"), to: &source, beat: 1, staff: Self.top)
        Self.add(Self.text("middle beat 3"), to: &source, beat: 2, staff: Self.middle)
        Self.add(Self.text("system beat 1", system: true), to: &source, beat: 0, staff: nil)

        let partial = try #require(source.clipboardDocument(for: VoiceElementRange(
            start: Self.slot(staff: Self.top, beat: 1),
            end: Self.slot(staff: Self.middle, beat: 3),
        )))
        #expect(Self.texts(in: partial, measure: 0).count == 2)
        #expect(Self.named("top beat 2", in: partial, measure: 0)?.position == .start)
        #expect(Self.named("top beat 2", in: partial, measure: 0)?.originalStaff == Self.top)
        #expect(Self.named("middle beat 3", in: partial, measure: 0)?.position
            == MeasurePosition(numerator: 1, denominator: 4))
        #expect(Self.named("middle beat 3", in: partial, measure: 0)?.originalStaff == Self.middle)
        #expect(Self.named("system beat 1", in: partial, measure: 0) == nil)

        let whole = try #require(source.clipboardDocument(for: VoiceElementRange(
            start: Self.slot(staff: Self.top, beat: 0),
            end: Self.slot(staff: Self.middle, beat: 3),
        )))
        #expect(Self.texts(in: whole, measure: 0).count == 3)
        #expect(Self.named("system beat 1", in: whole, measure: 0)?.originalStaff == nil)
    }

    @Test("a lower-staff-only range carries its staff text but no system text")
    func lowerStaffRangeExcludesSystemText() throws {
        var source = Self.score(measureCount: 1)
        Self.add(Self.text("top"), to: &source, beat: 1, staff: Self.top)
        Self.add(Self.text("middle"), to: &source, beat: 2, staff: Self.middle)
        Self.add(Self.text("system", system: true), to: &source, beat: 2, staff: nil)

        let payload = try #require(source.clipboardDocument(for: VoiceElementRange(
            start: Self.slot(staff: Self.middle, beat: 0),
            end: Self.slot(staff: Self.middle, beat: 3),
        )))
        let copied = Self.texts(in: payload, measure: 0)
        #expect(copied.count == 1)
        #expect(Self.named("middle", in: payload, measure: 0)?.originalStaff == Self.top)
    }

    @Test("clipboard texts survive MSCX encode and parse with placement and properties")
    func textsRoundTripThroughMSCX() throws {
        var source = Self.score(measureCount: 1)
        let color = ScoreColor(red: 12, green: 34, blue: 56, alpha: 78)
        Self.add(Self.text("colored", color: color, offsetX: 1.5), to: &source, beat: 2, staff: Self.middle)
        let payload = try #require(source.clipboardDocument(for: VoiceElementRange(
            start: Self.slot(staff: Self.top, beat: 1),
            end: Self.slot(staff: Self.middle, beat: 3),
        )))

        let parsed = try MSCXParser.parse(MSCXEncoder.encode(payload))
        let positioned = try #require(Self.named("colored", in: parsed, measure: 0))
        guard case let .staffText(parsedText) = positioned.element else {
            Issue.record("expected a staff text")
            return
        }
        #expect(positioned.position == MeasurePosition(numerator: 1, denominator: 4))
        #expect(positioned.originalStaff == Self.middle)
        #expect(parsedText.color == color)
        #expect(parsedText.offsetX == 1.5)
    }

    @Test("paste maps texts onto destination staves, replaces only matching beats, and undoes exactly")
    func pastePlacesReplacesAndUndoesTexts() throws {
        var source = Self.score(measureCount: 1)
        Self.add(Self.text("upper source"), to: &source, beat: 1, staff: Self.top)
        Self.add(Self.text("lower source"), to: &source, beat: 2, staff: Self.middle)
        Self.add(Self.text("system source", system: true), to: &source, beat: 0, staff: nil)
        let range = VoiceElementRange(
            start: Self.slot(staff: Self.top, beat: 0),
            end: Self.slot(staff: Self.middle, beat: 3),
        )
        let payload = try #require(source.clipboardDocument(for: range))
        let payloadText = try #require(String(data: MSCXEncoder.encode(payload), encoding: .utf8))

        var destination = Self.score(staffCount: 3)
        Self.add(Self.text("replace me"), to: &destination, measure: 1, beat: 1, staff: Self.middle)
        Self.add(Self.text("survivor"), to: &destination, measure: 1, beat: 3, staff: Self.middle)
        let beforeLane = destination.systemMeasures
        let session = ScoreEditSession(score: destination, payloadReader: MSCXParser.parse)

        #expect(session.apply(.pasteRange(
            at: Self.slot(staff: Self.middle, measure: 1, beat: 0), payload: payloadText,
        )))
        #expect(Self.named("replace me", in: session.score, measure: 1) == nil)
        #expect(Self.named("upper source", in: session.score, measure: 1)?.originalStaff == Self.middle)
        #expect(Self.named("upper source", in: session.score, measure: 1)?.position
            == MeasurePosition(numerator: 1, denominator: 4))
        #expect(Self.named("lower source", in: session.score, measure: 1)?.originalStaff == Self.bottom)
        #expect(Self.named("lower source", in: session.score, measure: 1)?.position
            == MeasurePosition(numerator: 2, denominator: 4))
        #expect(Self.named("system source", in: session.score, measure: 1)?.originalStaff == nil)
        #expect(Self.named("system source", in: session.score, measure: 1)?.position == .start)
        #expect(Self.named("survivor", in: session.score, measure: 1) != nil)
        #expect(session.undo())
        #expect(session.score.systemMeasures == beforeLane)
    }

    @Test("duplicate range repeats a staff text immediately after the range")
    func duplicateRepeatsStaffText() {
        var source = Self.score(staffCount: 1, measureCount: 2)
        Self.add(Self.text("pizz."), to: &source, beat: 1, staff: Self.top)
        let session = ScoreEditSession(score: source)
        let range = VoiceElementRange(
            start: Self.slot(staff: Self.top, beat: 0),
            end: Self.slot(staff: Self.top, beat: 3),
        )

        #expect(session.apply(.duplicateRange(over: range)))
        #expect(Self.named("pizz.", in: session.score, measure: 1)?.position
            == MeasurePosition(numerator: 1, denominator: 4))
        #expect(Self.named("pizz.", in: session.score, measure: 1)?.originalStaff == Self.top)
    }

    @Test("range text removals composed before delete remove carried texts without changing delete spelling")
    func cutCompositeRemovesTextsAndMatchesPlainDelete() {
        var source = Self.score(measureCount: 1)
        Self.add(Self.text("carried staff"), to: &source, beat: 1, staff: Self.middle)
        Self.add(Self.text("carried system", system: true), to: &source, beat: 2, staff: nil)
        Self.add(Self.text("outside"), to: &source, beat: 0, staff: Self.top)
        let range = VoiceElementRange(
            start: Self.slot(staff: Self.top, beat: 1),
            end: Self.slot(staff: Self.middle, beat: 2),
        )
        let removals = source.rangeTextRemovals(for: range)
        #expect(removals.count == 2)
        #expect(removals.contains(.setStaffText(
            anchor: Self.slot(staff: Self.middle, beat: 1), text: nil, isSystemText: false,
        )))
        #expect(removals.contains(.setStaffText(
            anchor: Self.slot(staff: Self.top, beat: 2), text: nil, isSystemText: true,
        )))

        let plainDelete = ScoreEditSession(score: source)
        #expect(plainDelete.apply(.deleteRange(over: range)))
        let cut = ScoreEditSession(score: source)
        #expect(cut.apply(.composite(removals + [.deleteRange(over: range)])))

        #expect(cut.score.parts == plainDelete.score.parts)
        #expect(Self.named("carried staff", in: cut.score, measure: 0) == nil)
        #expect(Self.named("carried system", in: cut.score, measure: 0) == nil)
        #expect(Self.named("outside", in: cut.score, measure: 0) != nil)
    }

    @Test("pasting a payload without texts leaves the destination system lane unchanged")
    func textlessPasteLeavesSystemLaneUntouched() throws {
        let source = Self.score(staffCount: 1, measureCount: 1)
        let payload = try #require(source.clipboardDocument(for: VoiceElementRange(
            start: Self.slot(staff: Self.top, beat: 0),
            end: Self.slot(staff: Self.top, beat: 3),
        )))
        let payloadText = try #require(String(data: MSCXEncoder.encode(payload), encoding: .utf8))
        var destination = Self.score(staffCount: 1)
        Self.add(Self.text("keep"), to: &destination, measure: 1, beat: 2, staff: Self.top)
        let before = destination.systemMeasures
        let session = ScoreEditSession(score: destination, payloadReader: MSCXParser.parse)

        #expect(session.apply(.pasteRange(
            at: Self.slot(staff: Self.top, measure: 1, beat: 0), payload: payloadText,
        )))
        #expect(session.score.systemMeasures == before)
    }
}
