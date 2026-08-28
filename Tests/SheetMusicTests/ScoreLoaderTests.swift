import Foundation
import SheetMusicCore
import SheetMusicLoader
import SheetMusicMSCX
import Testing

/// Covers what `ScoreLoader` adds over the sniffing it inherited from `ScoreBridge` (whose own suite still exercises
/// the delegation): the MIDI title fallback, the URL convenience, and the ZIP ambiguity.
struct ScoreLoaderTests {
    /// Through `TestResources`, not `Bundle.module`: under WASI the fixtures come from PackageToJS's
    /// preopened directory rather than a bundle, and reaching for the bundle directly returns nil there.
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try #require(TestResources.url(forResource: name, withExtension: ext))
    }

    @Test
    func sniffsEveryFormatItAccepts() throws {
        #expect(try ScoreLoader.sniff(Data(contentsOf: fixture("midi01", "mscx"))) == .mscx)
        #expect(try ScoreLoader.sniff(Data(contentsOf: fixture("midi01", "mscz"))) == .mscz)
        #expect(try ScoreLoader.sniff(Data(contentsOf: fixture("glissando-wavy", "musicxml"))) == .musicXML)
        #expect(try ScoreLoader.sniff(Data(contentsOf: fixture("midi01-ref", "mid"))) == .midi)
        #expect(ScoreLoader.sniff(Data("not a score".utf8)) == .unknown)
    }

    /// The four formats a file extension would have been trusted for, all reached through one call.
    @Test(arguments: [("midi01", "mscx"), ("midi01", "mscz"), ("glissando-wavy", "musicxml"), ("midi01-ref", "mid")])
    func loadsEveryFormatFromBytes(name: String, ext: String) throws {
        let score = try ScoreLoader.loadScore(bytes: Data(contentsOf: fixture(name, ext)))
        #expect(!score.parts.isEmpty)
    }

    /// A MIDI file carries no title of its own here, so the fallback is the only thing that can name it — and it is
    /// the one parameter a caller can silently forget, since every other format ignores it.
    @Test
    func midiTakesItsTitleFromTheSourceFilenameWhenGiven() throws {
        let bytes = try Data(contentsOf: fixture("midi01-ref", "mid"))
        let named = try ScoreLoader.loadScore(bytes: bytes, sourceFilename: "Sonata in C")
        let anonymous = try ScoreLoader.loadScore(bytes: bytes)
        #expect(named.metaTags["workTitle"] == "Sonata in C")
        #expect(anonymous.metaTags["workTitle"] != "Sonata in C")
    }

    /// The URL entry exists so a caller holding a path cannot forget the fallback above.
    @Test
    func loadingFromAURLTakesTheTitleFallbackFromTheFilename() throws {
        let score = try ScoreLoader.loadScore(contentsOf: fixture("midi01-ref", "mid"))
        #expect(score.metaTags["workTitle"] == "midi01-ref")
    }

    /// `.mscz` and `.mxl` share the ZIP magic, so the sniff cannot separate them and the load path has to try both.
    /// Asserted from the `.mscz` side because that is the branch order's fast path; the fallback is what a `.mxl`
    /// would exercise.
    @Test
    func zipContainersAreResolvedByParsingRatherThanByMagic() throws {
        let bytes = try Data(contentsOf: fixture("midi01", "mscz"))
        #expect(ScoreLoader.sniff(bytes) == .mscz)
        #expect(try !ScoreLoader.loadScore(bytes: bytes).parts.isEmpty)
    }

    @Test
    func unrecognizedBytesThrowRatherThanGuess() {
        #expect(throws: (any Error).self) {
            try ScoreLoader.loadScore(bytes: Data("not a score".utf8))
        }
    }

    /// MuseScore 1.x, which keeps the score's children directly under
    /// `<museScore>` with no `<Score>` wrapper at all.
    private static let museScore1 = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <museScore version="1.14">
      <programVersion>1.2</programVersion>
      <Division>480</Division>
      <Staff id="1">
        <Measure number="1"/>
        </Staff>
      </museScore>
    """.utf8)

    /// A file the reader cannot open should say which format it is,
    /// not which format it isn't. MuseScore 1 files are still out there
    /// — the corpus has one saved in 2015 — and the reader supports
    /// MS3/MS4 shapes (MS2 is parsed leniently with a warning).
    @Test
    func museScore1SaysSoRatherThanBlamingTheStructure() throws {
        let error = #expect(throws: SheetMusicError.self) {
            try ScoreLoader.loadScore(bytes: Self.museScore1)
        }
        guard case let .malformedScore(fault) = try #require(error) else {
            Issue.record("expected a malformedScore fault, got \(String(describing: error))")
            return
        }
        #expect(fault.code == "mscx.version.unsupported")
        #expect(fault.message.contains("1.14"))
    }

    /// …and the `.mscz` path must not bury it. A ZIP is either `.mscz`
    /// or `.mxl`, so the loader tries MuseScore and falls back to MXL —
    /// but once the container has yielded a `<museScore>` document, the
    /// MuseScore error is the true one. Reporting the MXL attempt's
    /// "no `<score-partwise>`" instead sends the reader looking for a
    /// MusicXML problem in a MuseScore file.
    @Test
    func aMuseScoreFaultSurvivesTheMxlFallback() throws {
        let container = try MSCZWriter.write(mscxData: Self.museScore1)
        let error = #expect(throws: SheetMusicError.self) {
            try ScoreLoader.loadScore(bytes: container)
        }
        guard case let .malformedScore(fault) = try #require(error) else {
            Issue.record("expected a malformedScore fault, got \(String(describing: error))")
            return
        }
        #expect(fault.code == "mscx.version.unsupported")
    }
}
