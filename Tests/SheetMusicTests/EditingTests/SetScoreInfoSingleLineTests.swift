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
}
