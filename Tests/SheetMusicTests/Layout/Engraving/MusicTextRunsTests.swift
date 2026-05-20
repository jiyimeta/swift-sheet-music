@testable import SheetMusicLayout
import Testing

@Suite("MusicTextRuns")
struct MusicTextRunsTests {
    @Test func plainTextProducesSingleTextRun() {
        let runs = MusicTextRuns.runs(in: "hello")
        #expect(runs.count == 1)
        #expect(runs[0].kind == .text)
        #expect(runs[0].text == "hello")
    }

    @Test func emptyStringProducesNoRuns() {
        #expect(MusicTextRuns.runs(in: "").isEmpty)
    }

    @Test func tempoStringSplitsIntoMusicAndText() {
        // U+E1D5 = SMuFL metNoteQuarterUp. Tempo strings start with
        // this glyph and continue with " = 128" in Edwin.
        let runs = MusicTextRuns.runs(in: "\u{E1D5} = 128")
        #expect(runs.count == 2)
        #expect(runs[0].kind == .musicSymbol)
        #expect(runs[0].text == "\u{E1D5}")
        #expect(runs[1].kind == .text)
        #expect(runs[1].text == " = 128")
    }

    @Test func consecutiveMusicSymbolsCoalesceIntoOneRun() {
        // metNoteQuarterUp + metAugmentationDot side by side stay in
        // one run so the renderer makes a single Bravura draw call.
        let runs = MusicTextRuns.runs(in: "\u{E1D5}\u{E1E7}")
        #expect(runs.count == 1)
        #expect(runs[0].kind == .musicSymbol)
        #expect(runs[0].text == "\u{E1D5}\u{E1E7}")
    }

    @Test func nonPUAUnicodeMusicCharsTreatedAsText() {
        // Standard Unicode ♩ (U+2669) lives outside the PUA so it's
        // text — renderers route it through Edwin's cascade rather
        // than Bravura.
        let runs = MusicTextRuns.runs(in: "♩ = 120")
        #expect(runs.count == 1)
        #expect(runs[0].kind == .text)
    }
}
