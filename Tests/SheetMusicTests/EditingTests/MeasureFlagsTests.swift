@testable import SheetMusicCore
import Testing

@Suite("Measure.Flags")
struct MeasureFlagsTests {
    @Test("flags round-trip through the accessor and leave everything else alone")
    func roundTrip() {
        var measure = Measure(voices: [Voice(elements: [.rest(duration: .measure)])], measureRepeatCount: 2)
        #expect(measure.flags == .none)
        #expect(measure.flags.isEmpty)
        var flags = Measure.Flags.none
        flags.lineBreak = true
        flags.endRepeatCount = 3
        flags.markers = [Marker(kind: .segno, label: "segno")]
        flags.jumps = [Jump(jumpTo: "start", playUntil: "fine", continueAt: "", playRepeats: false, text: "D.C.")]
        measure.flags = flags
        #expect(measure.lineBreak)
        #expect(measure.endRepeatCount == 3)
        #expect(measure.markers.count == 1)
        #expect(measure.jumps.first?.text == "D.C.")
        #expect(measure.measureRepeatCount == 2)
        #expect(measure.flags == flags)
        #expect(!measure.flags.isEmpty)
        measure.flags = .none
        #expect(measure == Measure(voices: [Voice(elements: [.rest(duration: .measure)])], measureRepeatCount: 2))
    }
}
