#if os(macOS)
import SheetMusicCore
@testable import SheetMusicUI
import SwiftUI
import Testing

@Suite("ScoreView rendering smoke")
struct ScoreViewRenderTests {

    @MainActor
    @Test("ScoreView renders a minimal score to a non-empty CGImage")
    func rendersMinimalScore() throws {
        guard #available(macOS 15.0, *) else { return }
        let note = Note(pitch: 60, tpc: 14)
        let m = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: [note]))
        ])])
        let staff = StaffContent(id: 1, measures: [m])
        let score = Score(division: 480, staves: [staff])
        let view = ScoreView(score: score)
            .frame(width: 600, height: 200)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = renderer.cgImage
        try #require(image != nil)
        #expect((image?.width ?? 0) > 0)
        #expect((image?.height ?? 0) > 0)
    }
}
#endif
