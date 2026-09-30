import Foundation
@testable import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout
@testable import SheetMusicRenderWindows
import Testing

/// `ScorePages` is `LayoutBridge.computePages` behind the host-facing API: the same pages and spans for the same
/// options, and a selection tint that re-encodes them without laying the score out again. Each comparison lays out
/// under one task-local provider: `swift test` runs every target's suites in one process, and suites elsewhere swap
/// the global provider, so two layouts a moment apart could otherwise measure with different fonts.
@Suite("ScorePages")
struct ScorePagesTests {
    @Test("compute gives the bridge's pages and spans for the same options")
    func computeMatchesTheBridge() throws {
        try FontMetrics.$scopedProvider.withValue(StubFontMetricsProvider()) {
            let score = try ScoreBridge.loadScore(bytes: Data(Self.musicXML().utf8))
            let options = ScorePageOptions(mode: .page)
            let pages = ScorePages.compute(score: score, pageWidthMM: 210, pageHeightMM: 297, options: options)
            let direct = LayoutBridge.computePages(
                score: score, pageWidthMM: 210, pageHeightMM: 297, options: options.wire(),
            )
            #expect(pages.pageCount == direct.pages.count)
            // Not vacuous: a single page would not tell a cut in the wrong place from no cut at all.
            #expect(pages.pageCount > 1)
            #expect(pages.pages == direct.pages)
            #expect(pages.spans == direct.spans)
            for page in 0 ..< pages.pageCount {
                let size = pages.pageSizeMM(page)
                #expect(size.width == 210 && size.height == 297, "page \(page + 1): \(size)")
            }
        }
    }

    @Test("the default options lay out one vertical page of the given width")
    func verticalByDefault() throws {
        let score = try ScoreBridge.loadScore(bytes: Data(Self.musicXML().utf8))
        let pages = ScorePages.compute(score: score, pageWidthMM: 180, pageHeightMM: 297)
        #expect(pages.pageCount == 1)
        #expect(pages.pageSizeMM(0).width == 180)
        #expect(pages.pageSizeMM(0).height > 297)
    }

    @Test("tinted draws the selection in its color on its own page, and no selection gives the pages back")
    func tinted() throws {
        try FontMetrics.$scopedProvider.withValue(StubFontMetricsProvider()) {
            let score = try ScoreBridge.loadScore(bytes: Data(Self.musicXML().utf8))
            let pages = ScorePages.compute(
                score: score, pageWidthMM: 210, pageHeightMM: 297, options: ScorePageOptions(mode: .page),
            )
            let color: UInt32 = 0xFF33_66FF
            let untinted = pages.tinted(argb: color, ids: [])
            #expect(untinted.pages == pages.pages)
            #expect(untinted.spans == pages.spans)

            // The first note of the first part: on the first page.
            let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
            let elements = try #require(score[staff]?.measures.first?.voices.first?.elements)
            let firstChord = elements.firstIndex { element in
                guard case let .chord(chord) = element else { return false }
                return !chord.notes.isEmpty
            }
            let chordIndex = try #require(firstChord)
            let note = ScoreItemID.note(NoteID(
                staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: chordIndex, noteIndexInChord: 0,
            ))
            let selected = pages.tinted(argb: color, ids: [note])
            let marker = DrawCommand.setColor(argb: color)
            // Evaluated outside `#expect`, which would otherwise have to expand the calls.
            let colorBefore = pages.pages[0].commands.contains(marker)
            let colorAfter = selected.pages[0].commands.contains(marker)
            #expect(selected.pageCount == pages.pageCount)
            #expect(!colorBefore, "the untinted page already uses the selection color")
            #expect(colorAfter, "the selected note is not drawn in the selection color")
            #expect(Array(selected.pages.dropFirst()) == Array(pages.pages.dropFirst()))
        }
    }

    /// Four parts of 96 measures of quarters: many systems of four staves, so several A4 pages.
    private static func musicXML() -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
        <part-list>

        """
        for part in 1 ... 4 {
            xml += "<score-part id=\"P\(part)\"><part-name>Part \(part)</part-name></score-part>\n"
        }
        xml += "</part-list>\n"
        for part in 1 ... 4 {
            xml += "<part id=\"P\(part)\">\n"
            for measure in 1 ... 96 {
                xml += "<measure number=\"\(measure)\">"
                if measure == 1 {
                    xml += "<attributes><divisions>1</divisions><key><fifths>0</fifths></key>"
                    xml += "<time><beats>4</beats><beat-type>4</beat-type></time>"
                    xml += "<clef><sign>G</sign><line>2</line></clef></attributes>"
                }
                for step in ["C", "D", "E", "F"] {
                    xml += "<note><pitch><step>\(step)</step><octave>5</octave></pitch>"
                    xml += "<duration>1</duration><type>quarter</type></note>"
                }
                xml += "</measure>\n"
            }
            xml += "</part>\n"
        }
        return xml + "</score-partwise>\n"
    }
}
