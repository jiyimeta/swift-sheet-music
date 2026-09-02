@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

@Suite("Parity fixture")
struct ParityFixtureTests {
    @Test("has the shape the parity replay script addresses")
    func shape() throws {
        let score = EditingFixtures.parityFixture()
        #expect(score.parts.count == 2)
        #expect(score.parts.allSatisfy { $0.staves.count == 1 && $0.staves[0].measures.count == 4 })
        let m0 = score.parts[0].staves[0].measures[0].voices[0].elements
        #expect(m0.count == 5)
        guard case let .chord(c) = m0[1] else { Issue.record("expected a chord at m0[1]"); return }
        #expect(c.notes[0].pitch == 60)
        #expect(score.parts[0].staves[0].measures[1].voices.count == 2)
        guard case let .chord(tied) = score.parts[0].staves[0].measures[2].voices[0].elements[0] else {
            Issue.record("expected a tied chord"); return
        }
        #expect(tied.notes[0].tieForward == 1)
        #expect(score.systemMeasures.isEmpty)
        #expect(score.stableFingerprint == EditingFixtures.parityFixture().stableFingerprint)

        // `==` fails here — verified by running it — but only on fields the parser is expected to normalize, not
        // on any musical content: `systemMeasures` (the fixture leaves it empty; the parser pads one entry per
        // bar) and `source` (the fixture has no `.source`; the parser stamps `.museScore(.v4)`). Comparing by
        // fingerprint instead, since it does not look at either field.
        let roundTripped = try MSCXParser.parse(MSCXEncoder.encode(score))
        #expect(roundTripped.stableFingerprint == score.stableFingerprint)
    }
}
