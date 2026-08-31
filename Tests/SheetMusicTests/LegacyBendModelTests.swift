import SheetMusicCore
import Testing

struct LegacyBendModelTests {
    @Test func defaultsMatchMuseScore() {
        let bend = LegacyBend(points: [
            LegacyBend.Point(time: 0, pitch: 0, vibrato: 0),
            LegacyBend.Point(time: 15, pitch: 100, vibrato: 0),
            LegacyBend.Point(time: 60, pitch: 100, vibrato: 0),
        ])
        #expect(bend.play)
        #expect(bend.lineWidth == nil)
        #expect(bend.fontFace == nil)
        #expect(bend.fontSize == nil)
        #expect(bend.fontStyle == nil)
    }

    @Test func noteCarriesLegacyBend() {
        var note = Note(pitch: 62, tpc: 16)
        #expect(note.legacyBend == nil)
        note.legacyBend = LegacyBend(points: [
            LegacyBend.Point(time: 0, pitch: 0, vibrato: 0),
            LegacyBend.Point(time: 60, pitch: 100, vibrato: 0),
        ])
        #expect(note.legacyBend?.points.count == 2)
    }
}
