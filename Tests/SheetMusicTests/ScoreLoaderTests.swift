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

    /// MSC 5.00 moved every score spanner into a `<Score><SpannerMap>`
    /// this decoder does not visit, and `detectVersion` folds any
    /// major >= 4 into `.v4`. Without the guard the file below would
    /// parse "successfully" with its slurs, hairpins, ottavas and
    /// voltas gone and no diagnostic raised, so the refusal has to be
    /// an error rather than a warning.
    ///
    /// Loading the unmodified 4.60 bytes is the other half: it proves
    /// the refusal comes from the guard rather than from anything
    /// structural in the fixture.
    @Test
    func museScore5WithASpannerMapIsRefusedRatherThanSilentlyEmptied() throws {
        let original = try Data(contentsOf: fixture("midi01", "mscx"))
        #expect(try !ScoreLoader.loadScore(bytes: original).parts.isEmpty)

        let error = #expect(throws: SheetMusicError.self) {
            try ScoreLoader.loadScore(bytes: Self.museScore5WithSpannerMap(original))
        }
        guard case let .malformedScore(fault) = try #require(error) else {
            Issue.record("expected a malformedScore fault, got \(String(describing: error))")
            return
        }
        #expect(fault.code == "mscx.version.tooNew")
        #expect(fault.message.contains("5.00"))
    }

    /// The guard refuses the shape it would get wrong, not the version
    /// number. MuseScore only writes `<SpannerMap>` when the score has
    /// spanners, so a spanner-free 5.00 score is still inside what the
    /// 4.x-shaped reader handles — and the MusicXML reference corpus is
    /// made of exactly those. Rejecting on the version alone would
    /// throw away files this package reads correctly today.
    @Test
    func museScore5WithoutASpannerMapStillLoads() throws {
        let retargeted = try Self.retargetedToMuseScore5(Data(contentsOf: fixture("midi01", "mscx")))
        #expect(try !ScoreLoader.loadScore(bytes: retargeted).parts.isEmpty)
    }

    /// …but it must not load in silence. The unaudited rest of the 5.00
    /// delta can still be dropped, and the diagnostic is the only way a
    /// host learns to distrust the score it just got.
    @Test
    func museScore5WithoutASpannerMapWarns() throws {
        let retargeted = try Self.retargetedToMuseScore5(Data(contentsOf: fixture("midi01", "mscx")))
        let result = try MSCXParser.parseWithDiagnostics(retargeted)
        #expect(result.diagnostics.contains { $0.code == "mscx.version.newerThanSupported" })
    }

    /// The code must differ from the MuseScore 1 refusal even though
    /// both arrive as `malformedScore`: one tells the reader's user to
    /// re-save the file, the other tells them this package has to ship
    /// support first. A host localising off `fault.code` cannot give
    /// both pieces of advice from one key.
    @Test
    func tooOldAndTooNewAreDistinguishableByCode() throws {
        let tooNewBytes = try Self.museScore5WithSpannerMap(Data(contentsOf: fixture("midi01", "mscx")))
        let tooOld = #expect(throws: SheetMusicError.self) {
            try ScoreLoader.loadScore(bytes: Self.museScore1)
        }
        let tooNew = #expect(throws: SheetMusicError.self) {
            try ScoreLoader.loadScore(bytes: tooNewBytes)
        }
        guard case let .malformedScore(oldFault) = try #require(tooOld),
              case let .malformedScore(newFault) = try #require(tooNew)
        else {
            Issue.record("expected two malformedScore faults")
            return
        }
        #expect(oldFault.code != newFault.code)
    }

    /// …and the `.mscz` path must not bury it, for the same reason the
    /// MuseScore 1 case must not: once the container has yielded a
    /// `<museScore>` document, the MuseScore error is the true one and
    /// the MXL fallback's "no `<score-partwise>`" is a red herring.
    @Test
    func aMuseScore5FaultSurvivesTheMxlFallback() throws {
        let bytes = try Self.museScore5WithSpannerMap(Data(contentsOf: fixture("midi01", "mscx")))
        let container = try MSCZWriter.write(mscxData: bytes)
        let error = #expect(throws: SheetMusicError.self) {
            try ScoreLoader.loadScore(bytes: container)
        }
        guard case let .malformedScore(fault) = try #require(error) else {
            Issue.record("expected a malformedScore fault, got \(String(describing: error))")
            return
        }
        #expect(fault.code == "mscx.version.tooNew")
    }

    /// Swap only the `<museScore>` version attribute. The `<?xml …?>`
    /// declaration also carries `version="1.0"`, so the match has to
    /// include the element name.
    ///
    /// Throwing on a no-op matters: if the fixture is ever re-saved
    /// under a different version the substitution would silently do
    /// nothing, and the tests above would then be asserting the guard's
    /// behaviour against an unmodified 4.60 file.
    private static func retargetedToMuseScore5(_ mscx: Data) throws -> Data {
        let text = try #require(String(bytes: mscx, encoding: .utf8))
        let retargeted = text.replacingOccurrences(
            of: #"<museScore version="4.60">"#,
            with: #"<museScore version="5.00">"#,
        )
        try #require(retargeted != text, "fixture no longer declares version=\"4.60\"")
        return Data(retargeted.utf8)
    }

    /// …and additionally graft on the node MuseScore 5 puts a score's
    /// spanners in. An empty `<SpannerMap>` is enough: the guard keys
    /// off the node's presence, which is exactly what a real 5.00 file
    /// with any slur or hairpin would carry.
    private static func museScore5WithSpannerMap(_ mscx: Data) throws -> Data {
        let text = try #require(String(bytes: retargetedToMuseScore5(mscx), encoding: .utf8))
        let grafted = text.replacingOccurrences(
            of: "<Score>",
            with: "<Score>\n    <SpannerMap/>",
        )
        try #require(grafted != text, "fixture no longer opens with <Score>")
        return Data(grafted.utf8)
    }
}
