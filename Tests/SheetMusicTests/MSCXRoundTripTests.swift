import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

@Suite("MSCX round-trip")
struct MSCXRoundTripTests {
    @Test("midi01.mscx parse → encode → parse preserves Score equality")
    func midi01RoundTrip() throws {
        let originalData = try MSCXFixtureLoader.mscxData("midi01")
        let original = try MSCXParser.parse(originalData)

        let encoded = try MSCXEncoder.encode(original)
        let roundTripped = try MSCXParser.parse(encoded)

        #expect(roundTripped == original)
    }

    @Test("midi01 round-trips through MSCZWriter.write(score:) → MSCZReader")
    func midi01MSCZRoundTrip() throws {
        let originalData = try MSCXFixtureLoader.mscxData("midi01")
        let original = try MSCXParser.parse(originalData)

        let mscz = try MSCZWriter.write(score: original)
        let roundTripped = try MSCZReader.parse(mscz)

        #expect(roundTripped == original)
    }
}
