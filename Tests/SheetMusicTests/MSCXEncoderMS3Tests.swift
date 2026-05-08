import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite("MSCXEncoder MS3 target")
struct MSCXEncoderMS3Tests {
    @Test("MSCXVersion has v3 and v4 cases")
    func mscxVersionCases() {
        let v3: MSCXVersion = .v3
        let v4: MSCXVersion = .v4
        #expect(v3 != v4)
    }

    @Test("MSCXEncoderOptions defaults to v4")
    func optionsDefaultsToV4() {
        let opts = MSCXEncoderOptions()
        #expect(opts.targetVersion == .v4)
    }

    @Test("MSCXEncoderOptions accepts v3")
    func optionsAcceptsV3() {
        let opts = MSCXEncoderOptions(targetVersion: .v3)
        #expect(opts.targetVersion == .v3)
    }

    @Test("MSCXEncoder.encode(_:options:) v4 default matches zero-arg")
    func encodeOptionsV4DefaultMatchesLegacy() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let legacy = try MSCXEncoder.encode(score)
        let options = try MSCXEncoder.encode(score, options: .init())
        #expect(legacy == options)
    }

    @Test("MSCZWriter.write(score:options:) round-trips score")
    func msczWriteOptionsRoundTrips() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let bytes = try MSCZWriter.write(score: score, options: .init())
        let reparsed = try MSCZReader.parse(bytes)
        #expect(reparsed.parts.count == score.parts.count)
    }

    @Test("SheetMusic.exportMSCZ accepts options")
    func sheetMusicExportMSCZAcceptsOptions() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ms3-export-\(UUID().uuidString).mscz")
        defer { try? FileManager.default.removeItem(at: url) }
        try SheetMusic.exportMSCZ(score, options: .init(targetVersion: .v3), to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("v3 root museScore version is 3.02")
    func v3RootVersionIs302() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
        let root = try XMLTreeParser.parse(bytes)
        #expect(root.attributes["version"] == "3.02")
    }

    @Test("v4 root museScore version is 4.60")
    func v4RootVersionIs460() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v4))
        let root = try XMLTreeParser.parse(bytes)
        #expect(root.attributes["version"] == "4.60")
    }
}
