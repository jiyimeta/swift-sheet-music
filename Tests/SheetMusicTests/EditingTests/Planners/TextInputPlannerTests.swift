@testable import SheetMusicCore
import Testing

@Suite("TextInputPlanner")
struct TextInputPlannerTests {
    private static let first = anchor(measure: 0, element: 1)

    @Test("staff text writes and reads through the uniform surface")
    func staffTextRoundTrip() throws {
        var score = EditingFixtures.parityFixture()

        _ = try TextInputPlanner.command(.staffText, at: Self.first, text: "pizz.").apply(to: &score)

        #expect(TextInputPlanner.currentText(.staffText, at: Self.first, in: score) == "pizz.")
    }

    @Test("system text writes and reads through the uniform surface")
    func systemTextRoundTrip() throws {
        var score = EditingFixtures.parityFixture()

        _ = try TextInputPlanner.command(.systemText, at: Self.first, text: "rit.").apply(to: &score)

        #expect(TextInputPlanner.currentText(.systemText, at: Self.first, in: score) == "rit.")
    }

    @Test("chord symbols write and read through the uniform surface")
    func chordSymbolRoundTrip() throws {
        var score = EditingFixtures.parityFixture()
        score.parts[0].staves[0].measures[0].voices[0].elements.insert(
            .harmony(Harmony(name: "C")),
            at: 1,
        )
        let chord = Self.anchor(measure: 0, element: 2)

        _ = try TextInputPlanner.command(.chordSymbol, at: chord, text: "Cmaj7").apply(to: &score)

        #expect(TextInputPlanner.currentText(.chordSymbol, at: chord, in: score) == "Cmaj7")
    }

    @Test("rehearsal marks write read and remove through the uniform surface")
    func rehearsalMarkRoundTrip() throws {
        var score = EditingFixtures.parityFixture()

        _ = try TextInputPlanner.command(.rehearsalMark, at: Self.first, text: "A").apply(to: &score)
        #expect(TextInputPlanner.currentText(.rehearsalMark, at: Self.first, in: score) == "A")

        _ = try TextInputPlanner.command(.rehearsalMark, at: Self.first, text: nil).apply(to: &score)
        #expect(TextInputPlanner.currentText(.rehearsalMark, at: Self.first, in: score) == nil)
    }

    @Test("element-attached text advances to the next rest")
    func elementTextAdvancesToRest() throws {
        let score = EditingFixtures.fourQuarterRests()
        let expected = Self.anchor(measure: 0, element: 2)

        for kind in [TextInputPlanner.Kind.staffText, .systemText, .chordSymbol] {
            let next = try #require(TextInputPlanner.nextAnchor(kind, after: Self.first, in: score))
            #expect(next == expected)
            #expect(score[next]?.isRest == true)
        }
    }

    @Test("rehearsal marks advance to the first timed element of the next bar")
    func rehearsalMarkAdvancesByMeasure() throws {
        let score = EditingFixtures.twoMeasuresOfQuarterRests()

        let next = try #require(TextInputPlanner.nextAnchor(.rehearsalMark, after: Self.first, in: score))

        #expect(next == Self.anchor(measure: 1, element: 0))
        #expect(TextInputPlanner.nextAnchor(.rehearsalMark, after: next, in: score) == nil)
    }

    @Test("empty text reaches each command's typed refusal")
    func emptyTextIsNotSwallowed() {
        let cases: [(TextInputPlanner.Kind, EditRefusal.Reason)] = [
            (.staffText, .emptyStaffText),
            (.systemText, .emptyStaffText),
            (.chordSymbol, .emptyChordSymbol),
            (.rehearsalMark, .emptyRehearsalMarkText),
        ]
        for (kind, expected) in cases {
            var score = EditingFixtures.parityFixture()
            let error = #expect(throws: SheetMusicError.self) {
                _ = try TextInputPlanner.command(kind, at: Self.first, text: " \n ").apply(to: &score)
            }
            #expect(Self.reason(of: error) == expected)
        }
    }

    @Test("applying pending text to a preview copy leaves the committed score unchanged")
    func previewCopyDoesNotMutateCommittedScore() throws {
        let committed = EditingFixtures.parityFixture()
        var preview = committed

        _ = try TextInputPlanner.command(
            .staffText,
            at: Self.first,
            text: "live",
        ).apply(to: &preview)

        #expect(TextInputPlanner.currentText(
            .staffText, at: Self.first, in: committed,
        ) == nil)
        #expect(TextInputPlanner.currentText(
            .staffText, at: Self.first, in: preview,
        ) == "live")
        #expect(preview != committed)
    }

    private static func anchor(measure: Int, element: Int) -> VoiceElementID {
        VoiceElementID(
            staff: EditingFixtures.staff0,
            measureIndex: measure,
            voiceIndex: 0,
            elementIndex: element,
        )
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }
}
