@testable import SheetMusicAudio
import Testing

@Suite("PlaybackState .exporting")
struct PlaybackStateExportingCaseTests {
    @Test(".exporting is a distinct case")
    func exportingIsDistinct() {
        let s: PlaybackState = .exporting
        #expect(s == .exporting)
        #expect(s != .playing)
        #expect(s != .paused)
        #expect(s != .stopped)
    }
}
