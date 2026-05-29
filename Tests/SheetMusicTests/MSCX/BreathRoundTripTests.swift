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
    static func mscxWith(subtype: String, pauseChild: String? = nil) -> String {
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
                  <Breath><subtype>\(subtype)</subtype>\(pauseLine)</Breath>
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
            let xml = Self.mscxWith(subtype: subtype)
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
        let xml = Self.mscxWith(subtype: "caesura")
        let score = try Self.parse(xml)
        let voice = score.parts[0].staves[0].measures[0].voices[0]
        guard case let .breath(b) = voice.elements[1] else {
            Issue.record("expected .breath"); return
        }
        #expect(b.pause == 0.5)
    }

    @Test("decode honours explicit <pause>")
    func decodeExplicitPause() throws {
        let xml = Self.mscxWith(subtype: "caesura", pauseChild: "1.25")
        let score = try Self.parse(xml)
        let voice = score.parts[0].staves[0].measures[0].voices[0]
        guard case let .breath(b) = voice.elements[1] else {
            Issue.record("expected .breath"); return
        }
        #expect(b.pause == 1.25)
    }

    @Test("unknown subtype falls back to .breathMark(.comma)")
    func unknownSubtypeFallback() throws {
        let xml = Self.mscxWith(subtype: "breathMarkBogusXYZ")
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
            let xml = Self.mscxWith(subtype: kind.mscxSubtype, pauseChild: "0.75")
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
}
