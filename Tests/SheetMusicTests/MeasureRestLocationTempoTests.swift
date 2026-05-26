import Foundation
import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

@Suite("MeasureRestLocationTempo")
struct MeasureRestLocationTempoTests {
    /// Regression: a `<Tempo>` placed after a full-measure rest and a
    /// backward `<location>` must be positioned relative to the bar
    /// END, not tick 0. MuseScore's write cursor sits at the bar end
    /// after a measure rest, so `<fractions>-1/8</fractions>` means
    /// "1/8 before the bar end" (7/8), NOT a negative position. A
    /// negative `MeasurePosition` rendered to a negative MIDI tick and
    /// tripped `MidiWriter`'s "events must be sorted by tick"
    /// precondition (crash when playing `奪い返して.mscz`).
    @Test("Tempo after measure rest + backward location is non-negative")
    func tempoAfterMeasureRestIsNonNegative() throws {
        let xml = """
        <Voice>
            <Rest>
                <durationType>measure</durationType>
                <duration>4/4</duration>
            </Rest>
            <location>
                <fractions>-1/8</fractions>
            </location>
            <Tempo>
                <tempo>1.7</tempo>
            </Tempo>
        </Voice>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let result = try Voice.decodeWithSystemElements(node)
        guard result.systemElements.count == 1 else {
            Issue.record(Comment(
                rawValue:
                "expected 1 lifted element, got \(result.systemElements.count)",
            ))
            return
        }
        let pos = result.systemElements[0].position.offset
        // bar end (4/4 = 1) minus 1/8 = 7/8 — never negative.
        #expect(pos.numerator >= 0)
        #expect(pos.numerator == 7)
        #expect(pos.denominator == 8)
    }
}
