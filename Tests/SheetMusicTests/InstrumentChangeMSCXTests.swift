import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

@Suite("InstrumentChange MSCX")
struct InstrumentChangeMSCXTests {
    /// The hand-authored MIT fixture under `Resources/own/`.
    static func fixture() throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: "instrument-change", withExtension: "mscx",
            ),
            "fixture not bundled: instrument-change.mscx",
        )
        return try Data(contentsOf: url)
    }

    @Test("the change lands on measure 2 as a system element")
    func decodesIntoSystemMeasures() throws {
        let score = try MSCXParser.parse(Self.fixture())
        let changes = score.systemMeasures[2].elements.compactMap { positioned -> (InstrumentChange, StaffAddress?)? in
            guard case let .instrumentChange(change) = positioned.element
            else { return nil }
            return (change, positioned.originalStaff)
        }
        #expect(changes.count == 1)
        let (change, staff) = try #require(changes.first)
        #expect(change.text == "to Accordion")
        #expect(change.isUserInitialized == true)
        #expect(change.instrument?.id == "accordion")
        #expect(change.instrument?.longName == "Accordion")
        #expect(change.instrument?.channel.program == 21)
        #expect(change.instrument?.channel.midiChannel == 5)
        // Playback scope is the PART, so this must never be nil —
        // MidiRenderer routes nil to staff (0,0).
        #expect(staff == StaffAddress(partIndex: 0, staffIndexInPart: 0))
    }

    @Test("no other measure grows a change")
    func onlyOneChange() throws {
        let score = try MSCXParser.parse(Self.fixture())
        let total = score.systemMeasures.reduce(0) { acc, measure in
            acc + measure.elements.count { positioned in
                if case .instrumentChange = positioned.element { return true }
                return false
            }
        }
        #expect(total == 1)
    }

    @Test("the part's tick-0 instrument is untouched")
    func partInstrumentUnchanged() throws {
        let score = try MSCXParser.parse(Self.fixture())
        #expect(score.parts[0].instrument.id == "piano")
        #expect(score.parts[0].instrument.channel.program == 0)
    }

    @Test("a text-only change keeps its text, drops the instrument, warns")
    func textOnlyChangeDegradesGracefully() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.40">
          <Score>
            <Division>480</Division>
            <Part>
              <Staff id="1"/>
              <Instrument id="piano"><Channel><program value="0"/></Channel></Instrument>
            </Part>
            <Staff id="1">
              <Measure>
                <voice>
                  <InstrumentChange><text>to Accordion</text></InstrumentChange>
                  <Rest><durationType>measure</durationType><duration>4/4</duration></Rest>
                </voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
        let result = try MSCXParser.parseWithDiagnostics(Data(xml.utf8))
        let changes = result.score.systemMeasures[0].elements.compactMap { positioned -> InstrumentChange? in
            guard case let .instrumentChange(c) = positioned.element else { return nil }
            return c
        }
        #expect(changes.first?.text == "to Accordion")
        #expect(changes.first?.instrument == nil)
        #expect(result.diagnostics.contains {
            $0.code == "mscx.instrumentChange.missingInstrument"
        })
    }

    @Test("parse → encode → parse preserves Score equality")
    func roundTripsThroughEncoder() throws {
        let original = try MSCXParser.parse(Self.fixture())
        let encoded = try MSCXEncoder.encode(original)
        let roundTripped = try MSCXParser.parse(encoded)
        #expect(roundTripped.withSource(.unknown) == original.withSource(.unknown))
    }

    @Test("the encoded subtree carries instrument, init and text")
    func encodedSubtreeShape() {
        var change = InstrumentChange(
            text: "to Accordion",
            instrument: Instrument(
                id: "accordion",
                longName: "Accordion",
                channels: [InstrumentChannel(program: 21, midiChannel: 5)],
            ),
            offsetY: -2,
            isUserInitialized: true,
        )
        change.visible = true
        let node = change.encode()
        #expect(node.name == "InstrumentChange")
        // MuseScore's own order: Instrument, init, then TextBase props.
        // `prefix` yields an ArraySlice, which has no `==` against an
        // Array — wrap it before comparing.
        #expect(Array(node.children.map(\.name).prefix(2)) == ["Instrument", "init"])
        #expect(node.first("Instrument")?.attributes["id"] == "accordion")
        #expect(node.first("init")?.text == "1")
        #expect(node.first("text")?.text == "to Accordion")
        #expect(node.first("offset")?.attributes["y"] == "-2")
    }

    @Test("a false init emits no <init> element")
    func initOmittedWhenFalse() {
        let node = InstrumentChange(text: "x").encode()
        // XMLTreeNode.first(_:) is a custom child lookup, not
        // Sequence.first(where:), so SwiftLint's
        // contains_over_first_not_nil rule fires as a false positive.
        // swiftlint:disable:next contains_over_first_not_nil
        #expect(node.first("init") == nil)
    }

    @Test("a text-only change encodes without an <Instrument>")
    func textOnlyEncodes() {
        let node = InstrumentChange(text: "x").encode()
        // swiftlint:disable:next contains_over_first_not_nil
        #expect(node.first("Instrument") == nil)
        #expect(node.first("text")?.text == "x")
    }

    @Test("the fixture's timeline is piano then accordion at measure 2")
    func fixtureTimeline() throws {
        let score = try MSCXParser.parse(Self.fixture())
        let timeline = score.instrumentTimeline(forPart: 0)
        #expect(timeline.map(\.instrument.id) == ["piano", "accordion"])
        #expect(timeline[1].measureIndex == 2)
    }
}
