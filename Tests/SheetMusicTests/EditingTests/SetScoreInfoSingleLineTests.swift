@testable import SheetMusicCore
import Testing

/// The hosts show a multi-line title or subtitle on one line (`FrameText.singleLineText`) and send that line back on
/// save. Saving the sheet UNCHANGED must not turn the engraved line break into a space.
@Suite("SetScoreInfo — single-line restatement")
struct SetScoreInfoSingleLineTests {
    private static let multiLine = "First line\nSecond line"

    /// A score whose `field` is engraved and stored as `text`, line breaks included.
    private static func score(_ field: ScoreInfoWrite.Field, text: String) -> Score {
        var score = Score.blank(BlankScoreTemplate(
            title: "T", composer: nil,
            parts: [.init(instrumentID: "piano", staves: [.init(clefType: "G")])],
            measureCount: 1,
        ))
        var frame = score.titleFrame ?? ScoreFrame(heightSp: 10, texts: [])
        let style = field.frameTextStyle ?? .title
        if let index = frame.texts.firstIndex(where: { $0.style == style }) {
            frame.texts[index].text = text
        } else {
            frame.texts.append(FrameText(style: style, text: text))
        }
        score.titleFrame = frame
        score.metaTags[field.metaTagKey] = text
        return score
    }

    private static func engraved(_ style: FrameText.Style, in score: Score) -> String? {
        score.titleFrame?.texts.first { $0.style == style }?.text
    }

    private static func plan(_ field: ScoreInfoWrite.Field, _ text: String, in score: Score) throws -> Bool {
        try ScoreEditSession.command(for: EditIntent.setScoreInfo(
            writes: [ScoreInfoWrite(field: field, text: text)],
        ), in: score, ids: EIDAllocator(), depth: 0) != nil
    }

    @Test func `the one-line form of a multi-line subtitle is a restatement`() throws {
        let score = Self.score(.subtitle, text: Self.multiLine)
        let write = ScoreInfoWrite(field: .subtitle, text: "First line Second line")
        #expect(SetScoreInfo.isRestatement([write], in: score))
        #expect(try !Self.plan(.subtitle, "First line Second line", in: score))
        #expect(Self.engraved(.subtitle, in: score) == Self.multiLine)
    }

    @Test func `an edited one-line subtitle is not a restatement`() throws {
        let score = Self.score(.subtitle, text: Self.multiLine)
        let write = ScoreInfoWrite(field: .subtitle, text: "First line Third")
        #expect(!SetScoreInfo.isRestatement([write], in: score))
        #expect(try Self.plan(.subtitle, "First line Third", in: score))
    }

    @Test func `the one-line form of a multi-line title is a restatement`() throws {
        let score = Self.score(.title, text: Self.multiLine)
        let write = ScoreInfoWrite(field: .title, text: "First line Second line")
        #expect(SetScoreInfo.isRestatement([write], in: score))
        #expect(try !Self.plan(.title, "First line Second line", in: score))
        #expect(Self.engraved(.title, in: score) == Self.multiLine)
    }

    @Test func `an edited one-line title is not a restatement`() throws {
        let score = Self.score(.title, text: Self.multiLine)
        let write = ScoreInfoWrite(field: .title, text: "First line Third")
        #expect(!SetScoreInfo.isRestatement([write], in: score))
        #expect(try Self.plan(.title, "First line Third", in: score))
    }

    @Test func `a single-line field behaves as before`() throws {
        let score = Self.score(.title, text: "Sonata")
        #expect(SetScoreInfo.isRestatement([ScoreInfoWrite(field: .title, text: "Sonata")], in: score))
        #expect(!SetScoreInfo.isRestatement([ScoreInfoWrite(field: .title, text: "Partita")], in: score))
        #expect(try Self.plan(.title, "Partita", in: score))
    }

    // MARK: - Saving with another field changed

    /// `score(field, text:)` with a composer engraved and stored too, so a save can change it alongside.
    private static func scoreWithComposer(_ field: ScoreInfoWrite.Field, text: String) -> Score {
        var result = Self.score(field, text: text)
        var frame = result.titleFrame ?? ScoreFrame(heightSp: 10, texts: [])
        frame.texts.append(FrameText(style: .composer, text: "Old"))
        result.titleFrame = frame
        result.metaTags[ScoreInfoWrite.Field.composer.metaTagKey] = "Old"
        return result
    }

    /// The writes a host's info sheet sends when only the composer changed: `field` as it displays it, on one line.
    @discardableResult
    private static func saveNewComposer(
        _ field: ScoreInfoWrite.Field, to score: inout Score,
    ) throws -> any EditCommand {
        try SetScoreInfo(writes: [
            ScoreInfoWrite(field: field, text: "First line Second line"),
            ScoreInfoWrite(field: .composer, text: "New"),
        ]).apply(to: &score)
    }

    @Test(arguments: [ScoreInfoWrite.Field.subtitle, .title])
    func `changing the composer keeps a multi-line credit's line breaks`(field: ScoreInfoWrite.Field) throws {
        let original = Self.scoreWithComposer(field, text: Self.multiLine)
        var score = original
        let inverse = try Self.saveNewComposer(field, to: &score)
        let style = try #require(field.frameTextStyle)
        #expect(Self.engraved(.composer, in: score) == "New")
        #expect(score.metaTags[ScoreInfoWrite.Field.composer.metaTagKey] == "New")
        #expect(Self.engraved(style, in: score) == Self.multiLine)
        #expect(score.metaTags[field.metaTagKey] == Self.multiLine)
        try inverse.apply(to: &score)
        #expect(score == original)
    }

    /// A MuseScore file often engraves a subtitle without storing it: the engraved text is still what the one-line
    /// form restates, so it keeps its line breaks and the metaTag takes the same text.
    @Test func `an engraved multi-line subtitle with no metaTag keeps its line breaks`() throws {
        var score = Self.scoreWithComposer(.subtitle, text: Self.multiLine)
        score.metaTags[ScoreInfoWrite.Field.subtitle.metaTagKey] = nil
        try Self.saveNewComposer(.subtitle, to: &score)
        #expect(Self.engraved(.subtitle, in: score) == Self.multiLine)
        #expect(score.metaTags[ScoreInfoWrite.Field.subtitle.metaTagKey] == Self.multiLine)
        #expect(Self.engraved(.composer, in: score) == "New")
    }

    /// The repair `isRestatement` protects survives the same save: a title stored only in the metaTag is engraved.
    @Test func `an unchanged title stored only in its metaTag is still engraved`() throws {
        var score = Self.scoreWithComposer(.title, text: "Sonata")
        score.titleFrame?.texts.removeAll { $0.style == .title }
        try SetScoreInfo(writes: [
            ScoreInfoWrite(field: .title, text: "Sonata"),
            ScoreInfoWrite(field: .composer, text: "New"),
        ]).apply(to: &score)
        #expect(Self.engraved(.title, in: score) == "Sonata")
        #expect(score.metaTags[ScoreInfoWrite.Field.title.metaTagKey] == "Sonata")
    }

    @Test func `an edited one-line subtitle saved with a new composer is written`() throws {
        var score = Self.scoreWithComposer(.subtitle, text: Self.multiLine)
        try SetScoreInfo(writes: [
            ScoreInfoWrite(field: .subtitle, text: "First line Third"),
            ScoreInfoWrite(field: .composer, text: "New"),
        ]).apply(to: &score)
        #expect(Self.engraved(.subtitle, in: score) == "First line Third")
        #expect(Self.engraved(.composer, in: score) == "New")
    }
}
