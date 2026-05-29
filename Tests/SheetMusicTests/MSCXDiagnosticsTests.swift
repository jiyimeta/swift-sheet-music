import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

struct MSCXDiagnosticsTests {
    @Test func cleanFile_yieldsEmptyDiagnostics_mscx() throws {
        let url = try #require(Bundle.module.url(
            forResource: "midi01", withExtension: "mscx",
        ))
        let result = try MSCXParser.parseWithDiagnostics(contentsOf: url)
        #expect(result.diagnostics.isEmpty)
        #expect(!result.score.parts.isEmpty)
    }

    @Test func cleanFile_yieldsEmptyDiagnostics_mscz() throws {
        let url = try #require(Bundle.module.url(
            forResource: "midi01", withExtension: "mscz",
        ))
        let result = try MSCZReader.parseWithDiagnostics(contentsOf: url)
        #expect(result.diagnostics.isEmpty)
        #expect(!result.score.parts.isEmpty)
    }
}
