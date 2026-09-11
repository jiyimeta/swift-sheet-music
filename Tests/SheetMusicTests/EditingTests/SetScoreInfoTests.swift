@testable import SheetMusicCore
import Testing

/// Writing a score's credits — the command behind "type a title and see it on the page".
///
/// Every assertion here checks BOTH places a credit lives, because the bug this replaces was precisely that they
/// disagreed: a title stored where a list could read it and absent from where the engraver looks.
@Suite("SetScoreInfo")
struct SetScoreInfoTests {
    private static func blank(measureCount: Int = 1, title: String = "T", composer: String? = nil) -> Score {
        Score.blank(BlankScoreTemplate(
            title: title, composer: composer,
            parts: [.init(instrumentID: "piano", staves: [.init(clefType: "G")])],
            measureCount: measureCount,
        ))
    }

    /// A score with no `<VBox>` at all — what a `Score` built without a title frame looks like.
    private static func frameless() -> Score {
        Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "piano"), staves: [Staff(measures: [
                Measure(voices: [Voice(elements: [.rest(duration: .whole)])]),
            ])])],
        )
    }

    private static func engraved(_ style: FrameText.Style, in score: Score) -> String? {
        score.titleFrame?.texts.first { $0.style == style }?.text
    }

    @Test func `a credit lands in both the metaTag and the engraved frame`() throws {
        var score = Self.blank()
        try SetScoreInfo(writes: [ScoreInfoWrite(field: .title, text: "Sonata")]).apply(to: &score)
        #expect(score.metaTags["workTitle"] == "Sonata")
        #expect(Self.engraved(.title, in: score) == "Sonata")
    }

    /// The case the whole command exists for: a score created from scratch has no `<VBox>`, so writing a title has
    /// to MAKE one — MuseScore's own "Add > Text > Title" behavior on an empty score.
    @Test func `writing into a score with no title frame creates one`() throws {
        var score = Self.frameless()
        #expect(score.titleFrame == nil)
        try SetScoreInfo(writes: [ScoreInfoWrite(field: .title, text: "Untitled")]).apply(to: &score)
        let frame = try #require(score.titleFrame)
        #expect(frame.heightSp == 10)
        #expect(frame.texts.map(\.style) == [.title])
    }

    /// Clearing a field on a score that has no frame must not conjure an empty one.
    @Test func `clearing a credit on a frameless score creates nothing`() throws {
        var score = Self.frameless()
        try SetScoreInfo(writes: [ScoreInfoWrite(field: .title, text: nil)]).apply(to: &score)
        #expect(score.titleFrame == nil)
        #expect(score.metaTags["workTitle"] == nil)
    }

    /// Arranger and copyright have no engraved role, so they are metadata-only — and must not invent a frame text
    /// under a style that does not exist.
    @Test func `arranger and copyright are metadata only`() throws {
        var score = Self.frameless()
        try SetScoreInfo(writes: [
            ScoreInfoWrite(field: .arranger, text: "Arr."),
            ScoreInfoWrite(field: .copyright, text: "© 2026"),
        ]).apply(to: &score)
        #expect(score.metaTags["arranger"] == "Arr.")
        #expect(score.metaTags["copyright"] == "© 2026")
        #expect(score.titleFrame == nil)
    }

    /// A new text is placed by engraving order, not appended — so a composer typed before a subtitle still sits
    /// below it on the page.
    @Test func `a new text is inserted in engraving order`() throws {
        var score = Self.frameless()
        try SetScoreInfo(writes: [ScoreInfoWrite(field: .composer, text: "C")]).apply(to: &score)
        try SetScoreInfo(writes: [ScoreInfoWrite(field: .title, text: "T")]).apply(to: &score)
        try SetScoreInfo(writes: [ScoreInfoWrite(field: .subtitle, text: "S")]).apply(to: &score)
        #expect(score.titleFrame?.texts.map(\.style) == [.title, .subtitle, .composer])
    }

    /// A rename mutates the existing text in place, so its authored offset survives — the promise `SetStaffText`
    /// makes about a mark's own properties.
    @Test func `a rename keeps the text's authored offset`() throws {
        var score = Self.frameless()
        score.titleFrame = ScoreFrame(
            heightSp: 14, texts: [FrameText(style: .title, text: "Old", fontSize: 30)],
        )
        try SetScoreInfo(writes: [ScoreInfoWrite(field: .title, text: "New")]).apply(to: &score)
        #expect(Self.engraved(.title, in: score) == "New")
        #expect(score.titleFrame?.texts.first?.fontSize == 30)
        #expect(score.titleFrame?.heightSp == 14)
    }

    @Test func `clearing a credit removes both the tag and the engraved text`() throws {
        var score = Self.blank(title: "Sonata", composer: "Bach")
        try SetScoreInfo(writes: [ScoreInfoWrite(field: .composer, text: nil)]).apply(to: &score)
        #expect(score.metaTags["composer"] == nil)
        #expect(Self.engraved(.composer, in: score) == nil)
        // The title is untouched — a write names one field, not the whole block.
        #expect(Self.engraved(.title, in: score) == "Sonata")
    }

    /// Whitespace-only input is the same as clearing, so "cleared" has one representation.
    @Test func `whitespace-only text clears the credit`() throws {
        var score = Self.blank(title: "Sonata")
        try SetScoreInfo(writes: [ScoreInfoWrite(field: .title, text: "   ")]).apply(to: &score)
        #expect(score.metaTags["workTitle"] == nil)
        #expect(Self.engraved(.title, in: score) == nil)
    }

    @Test func `text is trimmed on the way in`() throws {
        var score = Self.blank()
        try SetScoreInfo(writes: [ScoreInfoWrite(field: .title, text: "  Sonata\n")]).apply(to: &score)
        #expect(score.metaTags["workTitle"] == "Sonata")
        #expect(Self.engraved(.title, in: score) == "Sonata")
    }

    /// Undo restores the score exactly — including REMOVING a frame the command created, which a field-by-field
    /// inverse would have left behind as an empty box reserving vertical space.
    @Test func `undo removes a frame the command created`() throws {
        var score = Self.frameless()
        let before = score
        let inverse = try SetScoreInfo(writes: [ScoreInfoWrite(field: .title, text: "T")]).apply(to: &score)
        #expect(score.titleFrame != nil)
        try inverse.apply(to: &score)
        #expect(score.titleFrame == nil)
        #expect(score == before)
    }

    @Test func `undo restores a metaTag that was absent rather than empty`() throws {
        var score = Self.frameless()
        let before = score
        let inverse = try SetScoreInfo(writes: ScoreInfoWrite.Field.allCases.map {
            ScoreInfoWrite(field: $0, text: "x")
        }).apply(to: &score)
        try inverse.apply(to: &score)
        #expect(score.metaTags == before.metaTags)
        #expect(score == before)
    }

    @Test func `an empty write list is refused`() {
        var score = Self.blank()
        #expect(throws: (any Error).self) { try SetScoreInfo(writes: []).apply(to: &score) }
    }

    // MARK: - Planning

    @Test func `a restatement plans to nothing`() throws {
        var score = Self.blank()
        try SetScoreInfo(writes: [ScoreInfoWrite(field: .title, text: "Sonata")]).apply(to: &score)
        #expect(SetScoreInfo.isRestatement([ScoreInfoWrite(field: .title, text: "Sonata")], in: score))
        #expect(try ScoreEditSession.command(for: EditIntent.setScoreInfo(
            writes: [ScoreInfoWrite(field: .title, text: "Sonata")],
        ), in: score, ids: EIDAllocator(), depth: 0) == nil)
    }

    /// The state this command exists to REPAIR is not a restatement: a metaTag that already says the right thing
    /// while the page shows nothing still has to plan to a command, or the title never reaches the engraver.
    @Test func `a metaTag without its engraved text is not a restatement`() throws {
        var score = Self.frameless()
        score.metaTags["workTitle"] = "Sonata"
        #expect(!SetScoreInfo.isRestatement([ScoreInfoWrite(field: .title, text: "Sonata")], in: score))
        #expect(try ScoreEditSession.command(for: EditIntent.setScoreInfo(
            writes: [ScoreInfoWrite(field: .title, text: "Sonata")],
        ), in: score, ids: EIDAllocator(), depth: 0) != nil)
    }

    @Test func `a changed credit plans to a command`() throws {
        let score = Self.blank(title: "Sonata")
        #expect(try ScoreEditSession.command(for: EditIntent.setScoreInfo(
            writes: [ScoreInfoWrite(field: .title, text: "Partita")],
        ), in: score, ids: EIDAllocator(), depth: 0) != nil)
    }
}
