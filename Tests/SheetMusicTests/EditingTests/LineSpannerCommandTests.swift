@testable import SheetMusicCore
import Testing

/// The eight line spanners (63 hairpin, 64 pedal, 66 ottava, 67 textLine, 68 trill, 69 vibrato, 70 palmMute,
/// 71 letRing) are one shape with eight templates: a `.spanner` `VoiceElement` inserted immediately before the
/// range's first chord, ending at the END TICK of its last element. The harness below asserts that shape once;
/// each case adds its own payload assertion via one `Row` in `commands`.
@Suite("Line spanner commands")
struct LineSpannerCommandTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    /// Bar 0 elements 1…2 are the C4 and D4 quarters, so every command below spans the first half of the bar and
    /// must record `(measures: 0, fractions: 1/2)` — the mid-measure spelling.
    private static let range = VoiceElementRange(start: slot(0, 1), end: slot(0, 2))

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }

    /// One line-spanner command under test. `large_tuple` (`.swiftlint.yml`) caps tuples at 4 elements, so this
    /// is a named-field `Sendable` struct rather than the 5-tuple a bare `arguments:` list would suggest — the
    /// shape every later row (Tasks 6, 8–13) reuses verbatim.
    private struct Row: Sendable {
        let name: String
        let build: @Sendable (VoiceElementRange) -> any EditCommand
        let kind: Spanner.Kind
        let rawType: String
        /// Asserts the one field that makes this kind's payload what it is; `{ _ in true }` for kinds with no
        /// payload of their own (pedal, palm mute, let ring).
        let payload: @Sendable (Spanner) -> Bool
    }

    /// Every line-spanner command. Tasks 6 and 8…13 each append one row here.
    private static let commands: [Row] = [
        Row(
            name: "hairpin", build: { SetHairpin(over: $0, subtype: .decrescendo) },
            kind: .hairpin, rawType: "HairPin", payload: { $0.hairpin?.subtype == .decrescendo },
        ),
    ]

    @Test(
        "each line spanner is inserted before the first chord, ending at the last element's end tick",
        arguments: commands,
    )
    private func writesAndUndoes(entry: Row) throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let inverse = try entry.build(Self.range).apply(to: &score)
        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        #expect(elements.count == 6, "\(entry.name): exactly one element inserted")
        guard case let .spanner(written) = elements[1] else {
            Issue.record("\(entry.name): expected a spanner")
            return
        }
        #expect(written.kind == entry.kind)
        #expect(written.rawType == entry.rawType)
        #expect(written.nextMeasuresOffset == 0)
        #expect(written.nextFractionsOffset == Fraction(numerator: 1, denominator: 2))
        #expect(entry.payload(written), "\(entry.name): payload")
        #expect(score.parts[1] == before.parts[1], "\(entry.name): the cello is untouched")
        #expect(score.parts[0].staves[0].measures[1...] == before.parts[0].staves[0].measures[1...])
        _ = try inverse.apply(to: &score)
        #expect(score == before, "\(entry.name): undo is exact")
    }

    @Test(
        "a second spanner of the same kind at the same position is refused; a missing target is refused",
        arguments: commands,
    )
    private func refuses(entry: Row) throws {
        var score = EditingFixtures.parityFixture()
        _ = try entry.build(Self.range).apply(to: &score)
        let written = score
        // The chord moved to index 2; the spanner at 1 is still in its attachment run.
        let shifted = VoiceElementRange(start: Self.slot(0, 2), end: Self.slot(0, 3))
        let twice = #expect(throws: SheetMusicError.self) { _ = try entry.build(shifted).apply(to: &score) }
        #expect(Self.reason(of: twice) == .duplicateSpanner(at: Self.slot(0, 2), kind: entry.kind), "\(entry.name)")
        #expect(score == written, "\(entry.name): a refusal mutates nothing")
        let missing = VoiceElementRange(start: Self.slot(9, 0), end: Self.slot(9, 1))
        #expect(throws: SheetMusicError.self) { _ = try entry.build(missing).apply(to: &score) }
        #expect(score == written)
    }

    /// A hairpin over ONE whole note is legal and is what `testSingleNoteDynamics.mscx` is made of — the
    /// single-element refusal applies to slurs only.
    @Test("a single-element range is legal for a line spanner")
    func singleElementIsFine() throws {
        var score = EditingFixtures.parityFixture()
        let single = VoiceElementRange(start: Self.slot(3, 0), end: Self.slot(3, 0))
        _ = try SetHairpin(over: single, subtype: .crescendo).apply(to: &score)
        guard case let .spanner(written) = score.parts[0].staves[0].measures[3].voices[0].elements[0] else {
            Issue.record("expected the hairpin")
            return
        }
        // Bar 3 is the LAST bar and holds a measure rest, so the span ends at the SCORE end: the writer keeps
        // `m` on the last measure and spells the whole bar rather than rolling into a measure that is not there.
        #expect(written.nextMeasuresOffset == 0)
        #expect(written.nextFractionsOffset == Fraction(numerator: 1, denominator: 1))
    }
}
