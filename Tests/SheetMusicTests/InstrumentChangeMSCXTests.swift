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
}
