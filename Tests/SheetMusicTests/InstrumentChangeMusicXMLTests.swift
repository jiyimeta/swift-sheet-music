import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

@Suite("InstrumentChange MusicXML")
struct InstrumentChangeMusicXMLTests {
    static func fixture() throws -> Score {
        let url = try #require(
            Bundle.module.url(
                forResource: "instrument-change", withExtension: "musicxml",
            ),
            "fixture not bundled: instrument-change.musicxml",
        )
        return try MusicXMLParser.parse(Data(contentsOf: url))
    }

    @Test("the part's timeline is piano then accordion")
    func timelineMatchesTheMSCXPath() throws {
        let timeline = try Self.fixture().instrumentTimeline(forPart: 0)
        #expect(timeline.count == 2)
        #expect(timeline[0].instrument.channel.program == 0)
        #expect(timeline[1].instrument.channel.program == 21)
        #expect(timeline[1].measureIndex == 2)
    }

    @Test("originalStaff is stamped so the change is part-scoped")
    func originalStaffIsSet() throws {
        let score = try Self.fixture()
        let stamped = score.systemMeasures.flatMap(\.elements).filter {
            if case .instrumentChange = $0.element { return true }
            return false
        }
        #expect(!stamped.isEmpty)
        // MidiRenderer routes a nil originalStaff to staff (0,0), which
        // would silently re-instrument part 0.
        #expect(stamped.allSatisfy { $0.originalStaff != nil })
    }

    @Test("a part whose notes never switch id gets no change")
    func noSpuriousChanges() throws {
        let url = try #require(
            Bundle.module.url(forResource: "glissando-wavy", withExtension: "musicxml"),
        )
        let score = try MusicXMLParser.parse(Data(contentsOf: url))
        let changes = score.systemMeasures.flatMap(\.elements).count {
            if case .instrumentChange = $0.element { return true }
            return false
        }
        #expect(changes == 0)
    }
}
