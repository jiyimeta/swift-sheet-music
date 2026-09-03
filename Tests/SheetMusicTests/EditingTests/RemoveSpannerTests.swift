@testable import SheetMusicCore
import Testing

@Suite("RemoveSpanner")
struct RemoveSpannerTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }

    @Test("removes a line spanner element, shifting the later indices back, and undo restores them")
    func removesLineSpanner() throws {
        var score = EditingFixtures.parityFixture()
        let plain = score
        _ = try SetHairpin(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2)), subtype: .crescendo)
            .apply(to: &score)
        let written = score
        let inverse = try RemoveSpanner(at: Self.slot(0, 1), kind: .hairpin).apply(to: &score)
        #expect(score == plain)
        _ = try inverse.apply(to: &score)
        #expect(score == written)
    }

    @Test("removes every slur entry of the chord, leaving the chord itself alone")
    func removesSlurs() throws {
        var score = EditingFixtures.parityFixture()
        guard case var .chord(head) = score.parts[0].staves[0].measures[0].voices[0].elements[1] else {
            Issue.record("expected the C4"); return
        }
        head.spanners = [
            Spanner(kind: .slur, rawType: "Slur"),
            Spanner(kind: .slur, rawType: "Slur", nextMeasuresOffset: 1),
        ]
        score.parts[0].staves[0].measures[0].voices[0].elements[1] = .chord(head)
        _ = try RemoveSpanner(at: Self.slot(0, 1), kind: .slur).apply(to: &score)
        guard case let .chord(stripped) = score.parts[0].staves[0].measures[0].voices[0].elements[1] else {
            Issue.record("expected the C4"); return
        }
        #expect(stripped.spanners.isEmpty)
        #expect(stripped.notes == head.notes)
        #expect(stripped.duration == head.duration)
    }

    @Test("the other staff and the other bars are untouched")
    func siblingsUntouched() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetPedal(over: VoiceElementRange(start: Self.slot(2, 0), end: Self.slot(2, 1))).apply(to: &score)
        let before = score
        _ = try RemoveSpanner(at: Self.slot(2, 0), kind: .pedal).apply(to: &score)
        #expect(score.parts[1] == before.parts[1])
        #expect(score.parts[0].staves[0].measures[0 ..< 2] == before.parts[0].staves[0].measures[0 ..< 2])
    }

    @Test("a mismatched kind, a chord with no slur, a non-spanner element and a missing element are refused")
    func refusals() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetPedal(over: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2))).apply(to: &score)
        let written = score
        let wrongKind = #expect(throws: SheetMusicError.self) {
            _ = try RemoveSpanner(at: Self.slot(0, 1), kind: .hairpin).apply(to: &score)
        }
        #expect(Self.reason(of: wrongKind) == .noSpannerAtLocation(Self.slot(0, 1)))
        let noSlur = #expect(throws: SheetMusicError.self) {
            _ = try RemoveSpanner(at: Self.slot(0, 2), kind: .slur).apply(to: &score)
        }
        #expect(Self.reason(of: noSlur) == .noSpannerAtLocation(Self.slot(0, 2)))
        let notASpanner = #expect(throws: SheetMusicError.self) {
            _ = try RemoveSpanner(at: Self.slot(0, 0), kind: .pedal).apply(to: &score)
        }
        #expect(Self.reason(of: notASpanner) == .wrongElementKind(at: Self.slot(0, 0), expected: .spanner))
        #expect(throws: SheetMusicError.self) {
            _ = try RemoveSpanner(at: Self.slot(9, 0), kind: .pedal).apply(to: &score)
        }
        #expect(score == written)
    }
}
