import Foundation
@testable import SheetMusic
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

        #expect(roundTripped.withSource(.unknown) == original.withSource(.unknown))
    }

    #if !os(Android)
        @Test("midi01 round-trips through MSCZWriter.write(score:) → MSCZReader")
        func midi01MSCZRoundTrip() throws {
            let originalData = try MSCXFixtureLoader.mscxData("midi01")
            let original = try MSCXParser.parse(originalData)

            let mscz = try MSCZWriter.write(score: original)
            let roundTripped = try MSCZReader.parse(mscz)

            #expect(roundTripped.withSource(.unknown) == original.withSource(.unknown))
        }
    #endif

    @Test("SheetMusic.exportMSCX writes a parseable file")
    func facadeExportMSCX() throws {
        let originalData = try MSCXFixtureLoader.mscxData("midi01")
        let original = try MSCXParser.parse(originalData)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mscx")
        try SheetMusic.exportMSCX(original, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let roundTripped = try SheetMusic.loadScore(mscxURL: tmp)
        #expect(roundTripped.withSource(.unknown) == original.withSource(.unknown))
    }

    #if !os(Android)
        @Test("SheetMusic.exportMSCZ writes a parseable archive")
        func facadeExportMSCZ() throws {
            let originalData = try MSCXFixtureLoader.mscxData("midi01")
            let original = try MSCXParser.parse(originalData)

            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mscz")
            try SheetMusic.exportMSCZ(original, to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let roundTripped = try SheetMusic.loadScore(msczURL: tmp)
            #expect(roundTripped.withSource(.unknown) == original.withSource(.unknown))
        }
    #endif

    @Test("testRepeatsWithKeySigs.mscx round-trips through MSCXEncoder")
    func repeatsWithKeySigsRoundTrip() throws {
        let originalData = try MSCXFixtureLoader.mscxData("testRepeatsWithKeySigs")
        let original = try MSCXParser.parse(originalData)

        let encoded = try MSCXEncoder.encode(original)
        let roundTripped = try MSCXParser.parse(encoded)

        #expect(roundTripped.withSource(.unknown) == original.withSource(.unknown))
    }

    @Test("testVoltaTemp.mscx Volta spanners survive a parse → encode → parse")
    func voltaSpannersRoundTrip() throws {
        // Full Score equality on this fixture is gated on the deferred
        // `titleFrame` / `pageLayout` encoder work — see memory note
        // “MSCX export — Phase 2 follow-ups” item 4. Until then,
        // narrow the assertion to the bit this commit unlocks: every
        // `.spanner` element survives the encoder unchanged.
        let originalData = try MSCXFixtureLoader.mscxData("testVoltaTemp")
        let original = try MSCXParser.parse(originalData)

        let encoded = try MSCXEncoder.encode(original)
        let roundTripped = try MSCXParser.parse(encoded)

        #expect(spanners(in: roundTripped) == spanners(in: original))
        #expect(!spanners(in: original).isEmpty)
    }

    private func spanners(in score: Score) -> [Spanner] {
        score.parts.flatMap { part in
            part.staves.flatMap { staff in
                staff.measures.flatMap { measure in
                    measure.voices.flatMap { voice in
                        voice.elements.compactMap {
                            if case let .spanner(s) = $0 { return s }
                            return nil
                        }
                    }
                }
            }
        }
    }
}

extension Score {
    /// Returns a copy with `source` overridden — used in round-trip
    /// equality checks since `source` is loader-set metadata (which
    /// version of the file format we read), not score content.
    fileprivate func withSource(_ source: ScoreSource) -> Score {
        var copy = self
        copy.source = source
        return copy
    }
}
