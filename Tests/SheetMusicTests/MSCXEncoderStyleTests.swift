import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite("MSCXEncoder Style")
struct MSCXEncoderStyleTests {
    @Test("PageLayout round-trips with non-default A3 portrait values")
    func pageLayoutRoundTrip() throws {
        var style = ScoreStyle.museScoreDefaults
        style.pageLayout = PageLayout(
            width: 297.0 / 25.4,
            height: 420.0 / 25.4,
            printableWidth: 267.0 / 25.4,
            oddTopMargin: 20.0 / 25.4,
            oddBottomMargin: 20.0 / 25.4,
            oddLeftMargin: 15.0 / 25.4,
            evenTopMargin: 21.0 / 25.4,
            evenBottomMargin: 21.0 / 25.4,
            evenLeftMargin: 16.0 / 25.4,
            twosided: false
        )
        let original = Score(division: 480, style: style)

        let bytes = try MSCXEncoder.encode(original)
        let reparsed = try MSCXParser.parse(bytes)

        #expect(reparsed.style.pageLayout == style.pageLayout)
    }

    @Test("HeaderFooter round-trips toggled flags + custom rows")
    func headerFooterRoundTrip() throws {
        var style = ScoreStyle.museScoreDefaults
        style.pageChrome.header = HeaderFooter(
            enabled: true,
            showOnFirstPage: true,
            oddEvenDifferent: false,
            even: TextRow(left: "", center: "", right: ""),
            odd: TextRow(left: "L", center: "C", right: "R"),
            fontFace: "Helvetica",
            fontSize: 10,
            fontStyle: [.bold, .italic]
        )
        style.pageChrome.footer = HeaderFooter(
            enabled: false,
            showOnFirstPage: false,
            oddEvenDifferent: true,
            even: TextRow(left: "$P", center: "", right: ""),
            odd: TextRow(left: "", center: "", right: "$P"),
            fontFace: "Times New Roman",
            fontSize: 8,
            fontStyle: [.underline]
        )
        let original = Score(division: 480, style: style)

        let bytes = try MSCXEncoder.encode(original)
        let reparsed = try MSCXParser.parse(bytes)

        #expect(reparsed.style.pageChrome.header == style.pageChrome.header)
        #expect(reparsed.style.pageChrome.footer == style.pageChrome.footer)
    }

    @Test("PageNumberStyle round-trips toggled visibility + font")
    func pageNumberRoundTrip() throws {
        var style = ScoreStyle.museScoreDefaults
        style.pageChrome.pageNumber = PageNumberStyle(
            enabled: false,
            showOnFirstPage: true,
            oddEvenDifferent: false,
            fontFace: "Courier",
            fontSize: 13
        )
        let original = Score(division: 480, style: style)

        let bytes = try MSCXEncoder.encode(original)
        let reparsed = try MSCXParser.parse(bytes)

        #expect(
            reparsed.style.pageChrome.pageNumber
                == style.pageChrome.pageNumber
        )
    }

    @Test("Style round-trips spatium when chrome is at defaults")
    func defaultsRoundTrip() throws {
        let original = Score(
            division: 480, style: .museScoreDefaults
        )
        let bytes = try MSCXEncoder.encode(original)
        let reparsed = try MSCXParser.parse(bytes)

        #expect(reparsed.style == .museScoreDefaults)
    }
}
