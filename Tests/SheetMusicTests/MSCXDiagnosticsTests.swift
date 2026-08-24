import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

struct MSCXDiagnosticsTests {
    @Test func cleanFile_yieldsEmptyDiagnostics_mscx() throws {
        let url = try #require(TestResources.url(
            forResource: "midi01", withExtension: "mscx",
        ))
        let result = try MSCXParser.parseWithDiagnostics(contentsOf: url)
        #expect(result.diagnostics.isEmpty)
        #expect(!result.score.parts.isEmpty)
    }

    @Test func cleanFile_yieldsEmptyDiagnostics_mscz() throws {
        let url = try #require(TestResources.url(
            forResource: "midi01", withExtension: "mscz",
        ))
        let result = try MSCZReader.parseWithDiagnostics(contentsOf: url)
        #expect(result.diagnostics.isEmpty)
        #expect(!result.score.parts.isEmpty)
    }

    @Test func diagnostic_fixture_resource_resolves() {
        let url = TestResources.url(
            forResource: "diagnostics-tremolo-unknown-subtype",
            withExtension: "mscx",
        )
        #expect(url != nil)
    }

    @Test func unknownTremoloSubtype_emitsDiagnostic_andDropsTremolo() throws {
        let url = try #require(TestResources.url(
            forResource: "diagnostics-tremolo-unknown-subtype",
            withExtension: "mscx",
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
        let url = try #require(TestResources.url(
            forResource: "diagnostics-tremolo-unknown-subtype",
            withExtension: "mscx",
        ))
        let score = try MSCXParser.parse(contentsOf: url)
        #expect(score.parts.count == 1)
        let chord = firstChord(in: score)
        #expect(chord?.tremolo == nil)
    }

    @Test func missingTremoloSubtype_emitsDiagnostic_andDropsTremolo() throws {
        // Construct the XML in-line by stripping the <subtype> child from
        // the bundled fixture — keeps the assertion targeted on the
        // missing-subtype path.
        let url = try #require(TestResources.url(
            forResource: "diagnostics-tremolo-unknown-subtype",
            withExtension: "mscx",
        ))
        var xml = try String(contentsOf: url, encoding: .utf8)
        xml = xml.replacingOccurrences(
            of: "<subtype>r128</subtype>",
            with: "",
        )
        let result = try MSCXParser.parseWithDiagnostics(Data(xml.utf8))
        let chord = firstChord(in: result.score)
        #expect(chord?.tremolo == nil)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.code == "mscx.tremolo.missingSubtype")
    }

    @Test func diagnosticHasStableCode() throws {
        // The dotted-namespace contract is a public guarantee — if any
        // emitter drifts from it, callers' downstream filters break
        // silently. Verify a few known codes round-trip through a real
        // parse.
        let url = try #require(TestResources.url(
            forResource: "diagnostics-tremolo-unknown-subtype",
            withExtension: "mscx",
        ))
        let result = try MSCXParser.parseWithDiagnostics(contentsOf: url)
        for d in result.diagnostics {
            #expect(d.code.hasPrefix("mscx."))
            #expect(d.code.split(separator: ".").count >= 3)
        }
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
