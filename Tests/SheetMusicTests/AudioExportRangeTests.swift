@testable import SheetMusicAudioCore
import SheetMusicCore
import Testing

@Suite("AudioExportRange")
struct AudioExportRangeTests {
    @Test(".full is the default-equivalent case")
    func fullExists() {
        let r: AudioExportRange = .full
        if case .full = r { /* ok */ } else { Issue.record("Expected .full") }
    }

    @Test(".currentLoop is constructable")
    func currentLoopExists() {
        let r: AudioExportRange = .currentLoop
        if case .currentLoop = r { /* ok */ } else { Issue.record("Expected .currentLoop") }
    }

    @Test(".region carries two cursors")
    func regionCarriesCursors() {
        let start: ScoreCursor = .beat(measureIndex: 0, tickInMeasure: 0)
        let end: ScoreCursor = .beat(measureIndex: 1, tickInMeasure: 0)
        let r: AudioExportRange = .region(from: start, to: end)
        if case let .region(s, e) = r {
            #expect(s == start)
            #expect(e == end)
        } else {
            Issue.record("Expected .region")
        }
    }
}
