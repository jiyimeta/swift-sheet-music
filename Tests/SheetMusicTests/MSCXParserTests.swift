import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

@Suite struct MSCXParserTests {
    @Test func parsesMidi01() throws {
        let url = try #require(Bundle.module.url(forResource: "midi01", withExtension: "mscx"))
        let data = try Data(contentsOf: url)
        let score = try MSCXParser.parse(data)
        #expect(score.division == 480)
        #expect(score.parts.count == 1)
        #expect(score.parts[0].instrument.channel.program == 52)
        #expect(score.parts[0].instrument.longName == "Voice")
        #expect(score.staves.count == 1)
        #expect(score.staves[0].id == 1)
        #expect(score.staves[0].measures.count == 1)
        let voice = score.staves[0].measures[0].voices[0]
        #expect(voice.elements.count == 6)
        guard case .keySignature(let k) = voice.elements[0] else {
            Issue.record("element 0 not key sig")
            return
        }
        #expect(k.concertKey == 1)
        let pitches = voice.elements.compactMap {
            if case .chord(let c) = $0 { return c.notes.first?.pitch } else { return nil }
        }
        #expect(pitches == [60, 61, 62, 63])
    }
}
