@testable import SheetMusicCore
import Testing

struct Phase1ModelVisibilityTests {
    @Test func dynamicDefaultsVisible() {
        #expect(Dynamic(subtype: "mf", velocity: 80).visible == true)
    }

    @Test func noteVisibilitySugar() {
        var n = Note(pitch: 60, tpc: 14)
        #expect(n.visible == true)
        n.visible = false
        #expect(n.elementProperties.visible == false)
    }

    @Test func chordDefaultsVisible() {
        let c = Chord(duration: .quarter, notes: [])
        #expect(c.visible == true)
    }
}
