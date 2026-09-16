import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// Same ambiguity, same fix, as `LyricsVisibilityTests` — see the note there.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// The title-block credits a host can edit in place, and where each one sits.
///
/// A double-click on the title has to land on the TEXT the renderer drew, and an inline editor has to sit over it,
/// so the box is measured the way the layer renderer aligns the line (its ink, anchored per the text's alignment).
/// Only credits `SetScoreInfo` can write back are offered: the first text of each field's style, on one line.
@Suite("LayoutDocument — editable credit text")
struct CreditTextLineTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static func score(texts: [FrameText]) -> Score {
        let staff = Staff(measures: [Measure(voices: [Voice(elements: [.rest(duration: .measure)])])])
        var score = Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "voice"), staves: [staff])])
        score.titleFrame = ScoreFrame(heightSp: 10, texts: texts)
        return score
    }

    private static func layout(_ score: Score) -> LayoutDocument {
        LayoutEngine.layout(score: score, options: ScoreViewOptions(staffSize: 28), availableWidth: 900)
    }

    @Test("the four engraved credits are offered, one per field, in engraving order")
    func offersTheFourCredits() {
        let document = Self.layout(Self.score(texts: [
            FrameText(style: .title, text: "Sonata"),
            FrameText(style: .subtitle, text: "in C"),
            FrameText(style: .composer, text: "Anon."),
            FrameText(style: .lyricist, text: "Trad."),
        ]))
        #expect(document.creditTextLines.map(\.field) == [.title, .subtitle, .composer, .lyricist])
        #expect(document.creditTextLines.map(\.text) == ["Sonata", "in C", "Anon.", "Trad."])
    }

    /// `SetScoreInfo` rewrites the FIRST text of a style, so a second one — and a multi-line block, which a one-line
    /// field would flatten, and an unranked `.other` text — has nothing that would write an edit back to it.
    @Test("a second text of a style, a multi-line block and an unranked text are not offered")
    func leavesOutWhatCannotBeWrittenBack() {
        let document = Self.layout(Self.score(texts: [
            FrameText(style: .title, text: "Sonata"),
            FrameText(style: .title, text: "Second title"),
            FrameText(style: .lyricist, text: "Verse one\nVerse two"),
            FrameText(style: .other, text: "Dedication"),
        ]))
        #expect(document.creditTextLines.map(\.text) == ["Sonata"])
        #expect(document.creditTextLine(for: .lyricist) == nil)
    }

    @Test("a centered title's box is centered on its anchor, and a trailing composer's box ends at its anchor")
    func boxFollowsTheAlignment() throws {
        let document = Self.layout(Self.score(texts: [
            FrameText(style: .title, text: "Sonata"),
            FrameText(style: .composer, text: "Anon."),
        ]))
        let title = try #require(document.creditTextLine(for: .title))
        #expect(title.horizontalAnchor == 0.5)
        #expect(abs(title.frame.midX - title.origin.x) < 0.001)
        #expect(title.frame.width > 0)
        #expect(title.frame.minY == title.origin.y)
        #expect(title.frame.height > title.fontSize * 0.8)

        let composer = try #require(document.creditTextLine(for: .composer))
        #expect(composer.horizontalAnchor == 1)
        #expect(abs(composer.frame.maxX - composer.origin.x) < 0.001)
        // Bottom-anchored: the one line sits wholly above the anchor the engine resolved for the block.
        let entry = try #require(document.titleFrame?.texts.first { $0.style == .composer })
        #expect(composer.origin.y == entry.position.y - LayoutTitleFrame.lineHeight(fontSize: entry.fontSize))
    }

    @Test("a point inside a credit's box finds it, and a point clear of every box finds nothing")
    func hitTesting() throws {
        let document = Self.layout(Self.score(texts: [
            FrameText(style: .title, text: "Sonata"),
            FrameText(style: .composer, text: "Anon."),
        ]))
        let title = try #require(document.creditTextLine(for: .title))
        #expect(document.creditTextLine(at: CGPoint(x: title.frame.midX, y: title.frame.midY))?.field == .title)
        let beside = CGPoint(x: title.frame.maxX + 2, y: title.frame.midY)
        #expect(document.creditTextLine(at: beside)?.field != .title)
        #expect(document.creditTextLine(at: beside, tolerance: 4)?.field == .title)
        #expect(document.creditTextLine(at: CGPoint(x: -100, y: -100)) == nil)
    }

    @Test("a document with no title block offers nothing")
    func noTitleBlock() {
        var score = Self.score(texts: [])
        score.titleFrame = nil
        #expect(Self.layout(score).creditTextLines.isEmpty)
    }
}
