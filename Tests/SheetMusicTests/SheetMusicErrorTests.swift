import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

struct SheetMusicErrorTests {
    @Test func unsupportedFeatureCarriesNameAndLocation() {
        let error = SheetMusicError.unsupportedFeature(name: "Tuplet", location: "Voice")
        guard case let .unsupportedFeature(name, location) = error else {
            Issue.record("expected unsupportedFeature case")
            return
        }
        #expect(name == "Tuplet")
        #expect(location == "Voice")
    }

    @Test func corruptedContainerCarriesFault() {
        let fault = ScoreFault(code: "zip.corrupted", message: "bad zip")
        let error = SheetMusicError.corruptedContainer(fault)
        guard case let .corruptedContainer(payload) = error else {
            Issue.record("expected corruptedContainer")
            return
        }
        #expect(payload == fault)
        #expect(error.code == "zip.corrupted")
        #expect(error.developerDescription == "Corrupted archive: bad zip")
    }

    @Test func ioErrorPreservesURLAndUnderlying() {
        let url = URL(fileURLWithPath: "/tmp/missing.mscz")
        let underlying = NSError(domain: "TestDomain", code: 42)
        let error = SheetMusicError.ioError(url: url, underlying: underlying)
        guard case let .ioError(u, e) = error else {
            Issue.record("expected ioError")
            return
        }
        #expect(u == url)
        #expect((e as NSError).code == 42)
    }
}
