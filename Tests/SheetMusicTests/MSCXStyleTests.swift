import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

struct MSCXStyleTests {
    /// `testArpeggio.mscx` declares all eleven page geometry tags.
    /// We assert the parsed values match the literal XML to within
    /// 1e-5 (the file uses 6-digit fixed point).
    @Test func parsesAllPageGeometryTags() throws {
        let url = try #require(Bundle.module.url(
            forResource: "testArpeggio", withExtension: "mscx",
        ))
        let data = try Data(contentsOf: url)
        let score = try MSCXParser.parse(data)

        let layout = score.style.pageLayout
        #expect(abs(layout.width - 8.26771) < 1e-5)
        #expect(abs(layout.height - 11.6929) < 1e-4)
        #expect(abs(layout.printableWidth - 7.48031) < 1e-5)
        #expect(abs(layout.oddLeftMargin - 0.393701) < 1e-5)
        #expect(abs(layout.evenLeftMargin - 0.393701) < 1e-5)
        #expect(abs(layout.oddTopMargin - 0.393701) < 1e-5)
        #expect(abs(layout.evenTopMargin - 0.393701) < 1e-5)
        #expect(abs(layout.oddBottomMargin - 0.787403) < 1e-5)
        #expect(abs(layout.evenBottomMargin - 0.787403) < 1e-5)
        // testArpeggio doesn't override pageTwosided; it should
        // stay at MuseScore's default of true.
        #expect(layout.twosided == true)
        #expect(abs(score.style.spatium - 1.76389) < 1e-5)
    }

    /// A score without `<Style>` falls back to MuseScore's
    /// documented defaults end-to-end.
    @Test func defaultsWhenStyleAbsent() throws {
        let mscx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60">
          <Score>
            <Division>480</Division>
            <Part id="1"><Staff id="1"/><Instrument id="x"/></Part>
            <Staff id="1"><Measure></Measure></Staff>
          </Score>
        </museScore>
        """
        let score = try MSCXParser.parse(Data(mscx.utf8))
        #expect(score.style == ScoreStyle.museScoreDefaults)
    }

    /// The repo-root example (`Example/SheetMusicExample/test.mscx`)
    /// shape: `<Style><spatium>1.75</spatium></Style>`. Spatium
    /// captured, page layout untouched (== `.museScoreA4`).
    @Test func defaultsWhenStyleHasOnlySpatium() throws {
        let mscx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60">
          <Score>
            <Division>480</Division>
            <Style><spatium>1.75</spatium></Style>
            <Part id="1"><Staff id="1"/><Instrument id="x"/></Part>
            <Staff id="1"><Measure></Measure></Staff>
          </Score>
        </museScore>
        """
        let score = try MSCXParser.parse(Data(mscx.utf8))
        #expect(score.style.spatium == 1.75)
        #expect(score.style.pageLayout == .museScoreA4)
        #expect(score.style.pageChrome == .museScoreDefaults)
    }

    /// MuseScore writes capital `<Spatium>` today; older fixtures
    /// use lowercase. Both must parse — `style.cpp:385-386`.
    @Test func acceptsCapitalSpatium() throws {
        let mscx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60">
          <Score>
            <Division>480</Division>
            <Style><Spatium>2.0</Spatium></Style>
            <Part id="1"><Staff id="1"/><Instrument id="x"/></Part>
            <Staff id="1"><Measure></Measure></Staff>
          </Score>
        </museScore>
        """
        let score = try MSCXParser.parse(Data(mscx.utf8))
        #expect(score.style.spatium == 2.0)
    }

    /// All six text slots, both on/off toggles, and the first-page
    /// flag round-trip into `HeaderFooter.even/odd` and the booleans.
    @Test func parsesHeaderFooterText() throws {
        let mscx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60">
          <Score>
            <Division>480</Division>
            <Style>
              <showHeader>0</showHeader>
              <showFooter>1</showFooter>
              <headerFirstPage>1</headerFirstPage>
              <footerFirstPage>0</footerFirstPage>
              <headerOddEven>0</headerOddEven>
              <evenHeaderL>EH-L</evenHeaderL>
              <evenHeaderC>EH-C</evenHeaderC>
              <evenHeaderR>EH-R</evenHeaderR>
              <oddHeaderL>OH-L</oddHeaderL>
              <oddHeaderC>OH-C</oddHeaderC>
              <oddHeaderR>OH-R</oddHeaderR>
              <evenFooterL>EF-L</evenFooterL>
              <evenFooterC>EF-C</evenFooterC>
              <evenFooterR>EF-R</evenFooterR>
              <oddFooterL>OF-L</oddFooterL>
              <oddFooterC>OF-C</oddFooterC>
              <oddFooterR>OF-R</oddFooterR>
            </Style>
            <Part id="1"><Staff id="1"/><Instrument id="x"/></Part>
            <Staff id="1"><Measure></Measure></Staff>
          </Score>
        </museScore>
        """
        let score = try MSCXParser.parse(Data(mscx.utf8))
        let h = score.style.pageChrome.header
        #expect(h.enabled == false)
        #expect(h.showOnFirstPage == true)
        #expect(h.oddEvenDifferent == false)
        #expect(h.even.left == "EH-L")
        #expect(h.even.center == "EH-C")
        #expect(h.even.right == "EH-R")
        #expect(h.odd.left == "OH-L")
        #expect(h.odd.center == "OH-C")
        #expect(h.odd.right == "OH-R")

        let f = score.style.pageChrome.footer
        #expect(f.enabled == true)
        #expect(f.showOnFirstPage == false)
        #expect(f.even.left == "EF-L")
        #expect(f.odd.right == "OF-R")
    }

    /// `pageNumberFontSize` and `showPageNumberOne` round-trip into
    /// `PageNumberStyle`.
    @Test func parsesPageNumberStyle() throws {
        let mscx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60">
          <Score>
            <Division>480</Division>
            <Style>
              <showPageNumber>1</showPageNumber>
              <showPageNumberOne>1</showPageNumberOne>
              <pageNumberFontSize>13.5</pageNumberFontSize>
              <pageNumberFontFace>Helvetica</pageNumberFontFace>
            </Style>
            <Part id="1"><Staff id="1"/><Instrument id="x"/></Part>
            <Staff id="1"><Measure></Measure></Staff>
          </Score>
        </museScore>
        """
        let score = try MSCXParser.parse(Data(mscx.utf8))
        let pn = score.style.pageChrome.pageNumber
        #expect(pn.enabled == true)
        #expect(pn.showOnFirstPage == true)
        #expect(pn.fontFace == "Helvetica")
        #expect(pn.fontSize == 13.5)
    }
}
