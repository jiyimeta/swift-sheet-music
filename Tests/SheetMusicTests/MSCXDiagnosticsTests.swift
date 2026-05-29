import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

struct MSCXDiagnosticsTests {
    @Test func cleanFile_yieldsEmptyDiagnostics_mscx() throws {
        let url = try #require(Bundle.module.url(
            forResource: "midi01", withExtension: "mscx",
        ))
        let result = try MSCXParser.parseWithDiagnostics(contentsOf: url)
        #expect(result.diagnostics.isEmpty)
        #expect(!result.score.parts.isEmpty)
    }

    @Test func cleanFile_yieldsEmptyDiagnostics_mscz() throws {
        let url = try #require(Bundle.module.url(
            forResource: "midi01", withExtension: "mscz",
        ))
        let result = try MSCZReader.parseWithDiagnostics(contentsOf: url)
        #expect(result.diagnostics.isEmpty)
        #expect(!result.score.parts.isEmpty)
    }

    @Test func diagnostic_fixture_resource_resolves() {
        let url = Bundle.module.url(
            forResource: "diagnostics-tremolo-unknown-subtype",
            withExtension: "mscx",
            subdirectory: "own",
        )
        #expect(url != nil)
    }

    @Test func unknownTremoloSubtype_emitsDiagnostic_andDropsTremolo() throws {
        let url = try #require(Bundle.module.url(
            forResource: "diagnostics-tremolo-unknown-subtype",
            withExtension: "mscx",
            subdirectory: "own",
        ))
        let result = try MSCXParser.parseWithDiagnostics(contentsOf: url)

        // Score loaded.
        #expect(result.score.parts.count == 1)
        let chord = firstChord(in: result.score)
        #expect(chord != nil)
        // Tremolo was dropped — chord still present.
        #expect(chord?.tremolo == nil)

        // Exactly one diagnostic, with the stable code and the offending token.
        #expect(result.diagnostics.count == 1)
        let d = result.diagnostics.first
        #expect(d?.severity == .warning)
        #expect(d?.code == "mscx.tremolo.unknownSubtype")
        #expect(d?.message.contains("r128") == true)
    }

    @Test func breath_unknownSubtype_emitsDiagnostic() throws {
        // A direct-decode probe: feed a `<Breath>` with an unknown
        // subtype into the decoder under an active collector.
        let xml = """
        <Breath>
          <subtype>not-a-real-breath</subtype>
        </Breath>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let collector = MSCXDiagnosticCollector()
        let breath = MSCXParserContext.$collector.withValue(collector) {
            Breath.decodeMSCX(node)
        }
        // Decoder still returns a fallback breath.
        _ = breath
        #expect(collector.entries.count == 1)
        #expect(collector.entries.first?.code == "mscx.breath.unknownSubtype")
    }

    @Test func plainParse_alsoLoadsFileWithUnknownTremolo() throws {
        // The non-diagnostics API must also load (it just discards warnings).
        let url = try #require(Bundle.module.url(
            forResource: "diagnostics-tremolo-unknown-subtype",
            withExtension: "mscx",
            subdirectory: "own",
        ))
        let score = try MSCXParser.parse(contentsOf: url)
        #expect(score.parts.count == 1)
        let chord = firstChord(in: score)
        #expect(chord?.tremolo == nil)
    }
}

private func firstChord(in score: Score) -> Chord? {
    for part in score.parts {
        for staff in part.staves {
            for measure in staff.measures {
                for voice in measure.voices {
                    for el in voice.elements {
                        if case let .chord(c) = el, !c.notes.isEmpty {
                            return c
                        }
                    }
                }
            }
        }
    }
    return nil
}
