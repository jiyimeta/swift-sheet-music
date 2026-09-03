@testable import SheetMusicAudioCore
import Testing

@Suite("AudioExportError")
struct AudioExportErrorTests {
    @Test("Cases are Equatable")
    func equatable() {
        #expect(AudioExportError.noScorePrepared == .noScorePrepared)
        #expect(AudioExportError.cancelled == .cancelled)
        #expect(
            AudioExportError.engineSetupFailed(underlying: "x")
                == .engineSetupFailed(underlying: "x"),
        )
        #expect(
            AudioExportError.engineSetupFailed(underlying: "x")
                != .engineSetupFailed(underlying: "y"),
        )
    }

    @Test("formatUnsupportedOnThisOS carries the format")
    func formatUnsupportedCarriesFormat() {
        let err: AudioExportError = .formatUnsupportedOnThisOS(.mp3())
        if case let .formatUnsupportedOnThisOS(fmt) = err {
            if case .mp3 = fmt { /* ok */ } else { Issue.record("wrong fmt") }
        } else {
            Issue.record("wrong case")
        }
    }
}
