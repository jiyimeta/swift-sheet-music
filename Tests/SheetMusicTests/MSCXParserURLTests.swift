import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

struct MSCXParserURLTests {
    @Test func parseContentsOfURLMatchesDataOverload() throws {
        let url = try #require(
            TestResources.url(forResource: "midi01", withExtension: "mscx"),
        )
        let viaData = try MSCXParser.parse(Data(contentsOf: url))
        let viaURL = try MSCXParser.parse(contentsOf: url)
        #expect(viaData == viaURL)
    }

    @Test func parseContentsOfMissingURLThrowsIOError() {
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-there.mscx")
        do {
            _ = try MSCXParser.parse(contentsOf: missing)
            Issue.record("expected throw")
        } catch let error as SheetMusicError {
            guard case let .ioError(u, _) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(u == missing)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
