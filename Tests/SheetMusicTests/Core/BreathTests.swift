@testable import SheetMusicCore
import Testing

@Suite("Breath")
struct BreathTests {
    @Test("defaultPause returns MuseScore 4 values per kind")
    func defaultPausePerKind() {
        #expect(Breath.defaultPause(for: .breathMark(.comma)) == 0)
        #expect(Breath.defaultPause(for: .breathMark(.tick)) == 0)
        #expect(Breath.defaultPause(for: .breathMark(.upbow)) == 0)
        #expect(Breath.defaultPause(for: .breathMark(.salzedo)) == 0)
        #expect(Breath.defaultPause(for: .caesura(.normal)) == 0.5)
        #expect(Breath.defaultPause(for: .caesura(.short)) == 0.25)
        #expect(Breath.defaultPause(for: .caesura(.thick)) == 0.75)
        #expect(Breath.defaultPause(for: .caesura(.curved)) == 0.5)
    }

    @Test("init applies default pause when pause is nil")
    func initAppliesDefaultPause() {
        let b = Breath(kind: .caesura(.normal))
        #expect(b.pause == 0.5)
    }

    @Test("init accepts explicit pause overriding default")
    func initAcceptsExplicitPause() {
        let b = Breath(kind: .caesura(.normal), pause: 2.0)
        #expect(b.pause == 2.0)
    }

    @Test("visible sugar reflects elementProperties")
    func visibleSugar() {
        var b = Breath(kind: .breathMark(.comma))
        #expect(b.visible == true)
        b.visible = false
        #expect(b.elementProperties.visible == false)
    }

    @Test("VoiceElement.breath constructible and equatable")
    func voiceElementBreath() {
        let a: VoiceElement = .breath(Breath(kind: .breathMark(.tick)))
        let b: VoiceElement = .breath(Breath(kind: .breathMark(.tick)))
        #expect(a == b)
    }
}
