import Foundation
import SheetMusicLoader
import Testing

/// Covers what `ScoreLoader` adds over the sniffing it inherited from `ScoreBridge` (whose own suite still exercises
/// the delegation): the MIDI title fallback, the URL convenience, and the ZIP ambiguity.
struct ScoreLoaderTests {
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: ext))
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
}
