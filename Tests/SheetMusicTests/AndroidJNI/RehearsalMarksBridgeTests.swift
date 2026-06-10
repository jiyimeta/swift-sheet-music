import Foundation
@testable import SheetMusicAndroidJNI
@testable import SheetMusicCore
import Testing

struct RehearsalMarksBridgeTests {
    @Test func encodeDecodeRoundTrip() throws {
        let entries = [
            RehearsalMarkEntry(text: "A", fraction: 0.0, cursor: .beat(measureIndex: 0, tickInMeasure: 0)),
            RehearsalMarkEntry(text: "サビ", fraction: 0.5, cursor: .beat(measureIndex: 8, tickInMeasure: 240)),
        ]
        let decoded = try RehearsalMarkCodec.decode(RehearsalMarkCodec.encode(entries))
        #expect(decoded == entries)
    }

    @Test func emptyRoundTrip() throws {
        #expect(try RehearsalMarkCodec.decode(RehearsalMarkCodec.encode([])).isEmpty)
    }
}
