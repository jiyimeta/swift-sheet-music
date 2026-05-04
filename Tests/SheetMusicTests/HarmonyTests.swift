import Foundation
@testable import SheetMusicCore
import Testing

@Suite struct HarmonyTests {
    @Test func defaultsAreInert() {
        let h = Harmony(name: "C")
        #expect(h.name == "C")
        #expect(h.harmonyType == .standard)
        #expect(h.rootTpc == nil)
        #expect(h.bassTpc == nil)
        #expect(h.rootCase == .auto)
        #expect(h.bassCase == .auto)
        #expect(h.leftParen == false)
        #expect(h.rightParen == false)
        #expect(h.play == true)
        #expect(h.offsetX == 0)
        #expect(h.offsetY == 0)
        #expect(h.color == nil)
        #expect(h.styleType == .chordSymbolA)
    }

    @Test func styleTypeFollowsHarmonyType() {
        #expect(Harmony(name: "C", harmonyType: .standard).styleType
            == .chordSymbolA)
        #expect(Harmony(name: "I", harmonyType: .roman).styleType
            == .chordSymbolRomanNumeral)
        #expect(Harmony(name: "1", harmonyType: .nashville).styleType
            == .chordSymbolA)
    }

    @Test func voiceElementHarmonyCaseExists() {
        let element: VoiceElement = .harmony(Harmony(name: "C"))
        guard case let .harmony(h) = element else {
            Issue.record("expected .harmony case")
            return
        }
        #expect(h.name == "C")
    }
}
