#if os(macOS)
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicMSCX
    import Testing

    /// Writes this library's save of the marker fixture — plus a Coda and a Fine inserted the way folino inserts them,
    /// `Marker(kind:)` — to `SM_W3_RESAVE_OUT/markers-jumps-ssm.mscx`, for MuseScore to open (import fidelity W3,
    /// Task 11). Gated: a before/after tool, nothing committed reads its output.
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["SM_W3_RESAVE_OUT"] != nil))
    struct MarkerMuseScoreResaveTests {
        @Test("write the saved marker fixture")
        func write() throws {
            let directory = try #require(ProcessInfo.processInfo.environment["SM_W3_RESAVE_OUT"])
            var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("markers-jumps"))
            score.parts.updateValue(at: 0) { part in
                part.staves.updateValue(at: 0) { staff in
                    staff.measures[6].markers = [Marker(kind: .coda), Marker(kind: .fine)]
                }
            }
            let url = URL(fileURLWithPath: directory).appendingPathComponent("markers-jumps-ssm.mscx")
            try MSCXEncoder.encode(score).write(to: url)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }
#endif
