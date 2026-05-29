import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

@Suite("Breath MSCX round-trip")
struct BreathRoundTripTests {
    static func parse(_ xml: String) throws -> Score {
        try MSCXParser.parse(Data(xml.utf8))
    }

    /// Hand-authored MSCX containing one chord + a breath of each kind +
    /// another chord. Wrapped in a minimal Score / Measure / Voice
    /// envelope.
    static func mscxWith(symbol: String, pauseChild: String? = nil) -> String {
        let pauseLine = pauseChild.map { "<pause>\($0)</pause>" } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.40">
          <Score>
            <Division>480</Division>
            <Part>
              <Staff id="1"/>
              <Instrument id="piano"><trackName>Piano</trackName><Channel/></Instrument>
            </Part>
            <Staff id="1">
              <Measure>
                <voice>
                  <Chord><durationType>quarter</durationType>
                    <Note><pitch>60</pitch><tpc>14</tpc></Note>
                  </Chord>
                  <Breath><symbol>\(symbol)</symbol>\(pauseLine)</Breath>
                  <Chord><durationType>quarter</durationType>
                    <Note><pitch>62</pitch><tpc>16</tpc></Note>
                  </Chord>
                </voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
    }

    @Test("decode roundtrips all eight subtypes")
    func decodesAllEightSubtypes() throws {
        let cases: [(subtype: String, expected: Breath.Kind)] = [
            ("breathMarkComma", .breathMark(.comma)),
            ("breathMarkTick", .breathMark(.tick)),
            ("breathMarkUpbow", .breathMark(.upbow)),
            ("breathMarkSalzedo", .breathMark(.salzedo)),
            ("caesura", .caesura(.normal)),
            ("caesuraShort", .caesura(.short)),
            ("caesuraThick", .caesura(.thick)),
            ("caesuraCurved", .caesura(.curved)),
        ]
        for (subtype, expected) in cases {
            let xml = Self.mscxWith(symbol: subtype)
            let score = try Self.parse(xml)
            let voice = score.parts[0].staves[0].measures[0].voices[0]
            guard case let .breath(b) = voice.elements[1] else {
                Issue.record("expected .breath at index 1 for \(subtype)")
                continue
            }
            #expect(b.kind == expected)
        }
    }

    @Test("decode applies default pause when <pause> is absent")
    func decodeDefaultPause() throws {
        let xml = Self.mscxWith(symbol: "caesura")
        let score = try Self.parse(xml)
        let voice = score.parts[0].staves[0].measures[0].voices[0]
        guard case let .breath(b) = voice.elements[1] else {
            Issue.record("expected .breath"); return
        }
        #expect(b.pause == 0.5)
    }

    @Test("decode honours explicit <pause>")
    func decodeExplicitPause() throws {
        let xml = Self.mscxWith(symbol: "caesura", pauseChild: "1.25")
        let score = try Self.parse(xml)
        let voice = score.parts[0].staves[0].measures[0].voices[0]
        guard case let .breath(b) = voice.elements[1] else {
            Issue.record("expected .breath"); return
        }
        #expect(b.pause == 1.25)
    }

    @Test("unknown subtype falls back to .breathMark(.comma)")
    func unknownSubtypeFallback() throws {
        let xml = Self.mscxWith(symbol: "breathMarkBogusXYZ")
        let score = try Self.parse(xml)
        let voice = score.parts[0].staves[0].measures[0].voices[0]
        guard case let .breath(b) = voice.elements[1] else {
            Issue.record("expected .breath"); return
        }
        #expect(b.kind == .breathMark(.comma))
    }

    @Test("encode -> decode round-trip preserves kind and pause")
    func encodeDecodeRoundTrip() throws {
        let originals: [Breath.Kind] = [
            .breathMark(.comma), .breathMark(.tick),
            .breathMark(.upbow), .breathMark(.salzedo),
            .caesura(.normal), .caesura(.short),
            .caesura(.thick), .caesura(.curved),
        ]
        for kind in originals {
            let xml = Self.mscxWith(symbol: kind.mscxSubtype, pauseChild: "0.75")
            let parsed = try Self.parse(xml)
            // Re-encode and re-parse.
            let writtenData = try MSCXEncoder.encode(parsed)
            let written = try #require(String(data: writtenData, encoding: .utf8))
            let reparsed = try Self.parse(written)
            let voice = reparsed.parts[0].staves[0].measures[0].voices[0]
            guard case let .breath(b) = voice.elements[1] else {
                Issue.record("expected .breath after re-parse for \(kind)")
                continue
            }
            #expect(b.kind == kind)
            #expect(b.pause == 0.75)
        }
    }

    @Test("decoder still accepts legacy <subtype> form for backwards compat")
    func decodesLegacySubtype() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.40">
          <Score>
            <Division>480</Division>
            <Part>
              <Staff id="1"/>
              <Instrument id="piano"><trackName>Piano</trackName><Channel/></Instrument>
            </Part>
            <Staff id="1">
              <Measure>
                <voice>
                  <Chord><durationType>quarter</durationType>
                    <Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
                  <Breath><subtype>caesuraThick</subtype><pause>1.5</pause></Breath>
                  <Chord><durationType>quarter</durationType>
                    <Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
                </voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
        let score = try Self.parse(xml)
        let voice = score.parts[0].staves[0].measures[0].voices[0]
        guard case let .breath(b) = voice.elements[1] else {
            Issue.record("expected .breath"); return
        }
        #expect(b.kind == .caesura(.thick))
        #expect(b.pause == 1.5)
    }

    @Test("MuseScore 3.6.2 fixture: all 8 symbols decode with correct kinds and pauses")
    func musescoreThreeFixtureDecodesAllSymbols() throws {
        // User-provided fixture unpacked from ~/Desktop/test_breath.mscz.
        // Path is intentional: this test only runs locally where the file
        // exists, mirroring the project's "fixtures we own" rule.
        let path = "/tmp/test_breath_unpacked/test_breath.mscx"
        guard FileManager.default.fileExists(atPath: path) else {
            // Fixture absent on CI / fresh checkouts — skip rather than fail.
            return
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let score = try MSCXParser.parse(data)

        // Collect all .breath elements in document order.
        var breaths: [Breath] = []
        for part in score.parts {
            for staff in part.staves {
                for measure in staff.measures {
                    for voice in measure.voices {
                        for el in voice.elements {
                            if case let .breath(b) = el { breaths.append(b) }
                        }
                    }
                }
            }
        }
        #expect(breaths.count == 8)

        // Expected order from the fixture (visible in test_breath.mscx):
        let expected: [(Breath.Kind, Double)] = [
            (.breathMark(.comma), 0.0),
            (.breathMark(.tick), 0.0),
            (.breathMark(.salzedo), 0.0),
            (.breathMark(.upbow), 0.0),
            (.caesura(.curved), 2.0),
            (.caesura(.normal), 2.0),
            (.caesura(.short), 2.0),
            (.caesura(.thick), 2.0),
        ]
        for (i, (expectedKind, expectedPause)) in expected.enumerated() {
            guard i < breaths.count else { break }
            #expect(breaths[i].kind == expectedKind, "breath \(i) kind mismatch")
            #expect(breaths[i].pause == expectedPause, "breath \(i) pause mismatch")
        }
    }
}
