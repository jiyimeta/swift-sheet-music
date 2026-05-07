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
}
