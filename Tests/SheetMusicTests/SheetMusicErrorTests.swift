import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

@Suite struct SheetMusicErrorTests {
    @Test func unsupportedFeatureCarriesNameAndLocation() {
        let error = SheetMusicError.unsupportedFeature(name: "Tuplet", location: "Voice")
        guard case let .unsupportedFeature(name, location) = error else {
            Issue.record("expected unsupportedFeature case")
            return
        }
        #expect(name == "Tuplet")
        #expect(location == "Voice")
    }

    @Test func corruptedContainerCarriesReason() {
        let error = SheetMusicError.corruptedContainer(reason: "bad zip")
        guard case let .corruptedContainer(reason) = error else {
            Issue.record("expected corruptedContainer")
            return
        }
        #expect(reason == "bad zip")
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
