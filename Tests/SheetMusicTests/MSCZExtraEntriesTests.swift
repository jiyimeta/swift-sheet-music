import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicZip
import Testing

/// `MSCZWriter` pass-through entries and the reader side that hands them back.
///
/// A host stores its own sidecar next to the score — folino's `.folino` is an `.mscz` plus
/// `folino/annotations.json` and friends — so the container has to carry entries this library
/// knows nothing about, and give them back unchanged on the next read.
struct MSCZExtraEntriesTests {
    private func mainMSCXData() throws -> Data {
        let mscx = try #require(
            TestResources.url(forResource: "midi01", withExtension: "mscx"),
        )
        return try Data(contentsOf: mscx)
    }

    // MARK: - Writing

    @Test func extraEntriesAppearWithGivenBytesAndOrder() throws {
        let mscxData = try mainMSCXData()
        let extras = [
            MSCZExtraEntry(path: "folino/annotations.json", data: Data(#"{"a":1}"#.utf8)),
            MSCZExtraEntry(path: "folino/prefs.json", data: Data(#"{"b":2}"#.utf8)),
            MSCZExtraEntry(
                path: "folino/ink/1.pkdrawing",
                data: Data([0x00, 0x01, 0x02]),
                compression: .stored,
            ),
        ]
        let mscz = try MSCZWriter.write(mscxData: mscxData, extraEntries: extras)
        let reader = try ZipReader(data: mscz)

        for extra in extras {
            #expect(try reader.read(path: extra.path) == extra.data)
        }
        #expect(reader.entries["folino/ink/1.pkdrawing"]?.method == .stored)
        #expect(reader.entries["folino/prefs.json"]?.method == .deflate)

        // The two fixed entries come first, then the extras in the order given.
        let written = reader.entries.values
            .sorted { ($0.payloadRange?.lowerBound ?? 0) < ($1.payloadRange?.lowerBound ?? 0) }
            .map(\.path)
        #expect(written == [
            "META-INF/container.xml",
            "score.mscx",
            "folino/annotations.json",
            "folino/prefs.json",
            "folino/ink/1.pkdrawing",
        ])
    }

    @Test func writingExtrasIsDeterministic() throws {
        let mscxData = try mainMSCXData()
        let extras = [MSCZExtraEntry(path: "folino/prefs.json", data: Data(#"{"b":2}"#.utf8))]
        let first = try MSCZWriter.write(mscxData: mscxData, extraEntries: extras)
        let second = try MSCZWriter.write(mscxData: mscxData, extraEntries: extras)
        #expect(first == second)
    }

    @Test func archiveWithExtrasStillParses() throws {
        let mscxData = try mainMSCXData()
        let mscz = try MSCZWriter.write(
            mscxData: mscxData,
            extraEntries: [
                MSCZExtraEntry(path: "folino/annotations.json", data: Data(#"{"a":1}"#.utf8)),
            ],
        )
        let score = try MSCZReader.parse(mscz)
        let direct = try MSCXParser.parse(mscxData)
        #expect(score == direct)
    }

    @Test func nestedExtraEntryIsListedInTheCentralDirectory() throws {
        let mscxData = try mainMSCXData()
        let mscz = try MSCZWriter.write(
            mscxData: mscxData,
            extraEntries: [MSCZExtraEntry(path: "x/y/z.bin", data: Data([0xFF, 0xEE]))],
        )
        let reader = try ZipReader(data: mscz)
        #expect(reader.entries.count == 3)
        #expect(reader.contains(path: "x/y/z.bin"))
        #expect(try reader.read(path: "x/y/z.bin") == Data([0xFF, 0xEE]))
    }

    @Test func scoreOverloadCarriesExtras() throws {
        let score = try MSCXParser.parse(mainMSCXData())
        let mscz = try MSCZWriter.write(
            score: score,
            options: MSCXEncoderOptions(),
            extraEntries: [MSCZExtraEntry(path: "folino/prefs.json", data: Data([0x7B, 0x7D]))],
        )
        let reader = try ZipReader(data: mscz)
        #expect(try reader.read(path: "folino/prefs.json") == Data([0x7B, 0x7D]))
    }

    @Test func writeToURLCarriesExtras() throws {
        let mscxData = try mainMSCXData()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mscz-extras-test-\(UUID().uuidString).mscz")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try MSCZWriter.write(
            mscxData: mscxData,
            to: tmp,
            extraEntries: [MSCZExtraEntry(path: "folino/prefs.json", data: Data([0x7B, 0x7D]))],
        )
        let reader = try ZipReader(data: Data(contentsOf: tmp))
        #expect(try reader.read(path: "folino/prefs.json") == Data([0x7B, 0x7D]))
    }

    // MARK: - Validation

    private func expectFault(
        _ code: String,
        _ body: () throws -> some Any,
        sourceLocation: SourceLocation = #_sourceLocation,
    ) {
        do {
            _ = try body()
            Issue.record("expected throw", sourceLocation: sourceLocation)
        } catch let error as SheetMusicError {
            guard case let .corruptedContainer(fault) = error else {
                Issue.record("wrong case: \(error)", sourceLocation: sourceLocation)
                return
            }
            #expect(fault.code == code, sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }

    private func write(extraPaths: [String]) throws -> Data {
        try MSCZWriter.write(
            mscxData: Data([0x3C, 0x78, 0x6D, 0x6C]),
            extraEntries: extraPaths.map { MSCZExtraEntry(path: $0, data: Data([0x00])) },
        )
    }

    @Test func emptyExtraPathThrows() {
        expectFault("mscz.extraEntry.emptyPath") { try write(extraPaths: [""]) }
    }

    @Test func absoluteExtraPathThrows() {
        expectFault("mscz.extraEntry.absolutePath") { try write(extraPaths: ["/folino/a.json"]) }
    }

    @Test func parentSegmentInExtraPathThrows() {
        expectFault("mscz.extraEntry.parentSegment") { try write(extraPaths: ["folino/../a.json"]) }
        expectFault("mscz.extraEntry.parentSegment") { try write(extraPaths: ["../a.json"]) }
        expectFault("mscz.extraEntry.parentSegment") { try write(extraPaths: ["folino/.."]) }
    }

    @Test func containerXMLAsExtraPathThrows() {
        expectFault("mscz.extraEntry.reservedPath") {
            try write(extraPaths: ["META-INF/container.xml"])
        }
    }

    @Test func mainFileNameAsExtraPathThrows() {
        expectFault("mscz.extraEntry.mainFileNameCollision") {
            try MSCZWriter.write(
                mscxData: Data([0x3C, 0x78]),
                mainFileName: "renamed.mscx",
                extraEntries: [MSCZExtraEntry(path: "renamed.mscx", data: Data([0x00]))],
            )
        }
    }

    @Test func duplicateExtraPathsThrow() {
        expectFault("mscz.extraEntry.duplicatePath") {
            try write(extraPaths: ["folino/a.json", "folino/a.json"])
        }
    }

    @Test func aPathWhoseSegmentMerelyStartsWithDotsIsAllowed() throws {
        // `..foo` is not a parent segment; only an exact `..` is.
        let mscz = try write(extraPaths: ["folino/..foo.json"])
        let reader = try ZipReader(data: mscz)
        #expect(reader.contains(path: "folino/..foo.json"))
    }

    // MARK: - Reading back

    @Test func readerReturnsTheEntriesThatWereWritten() throws {
        let mscxData = try mainMSCXData()
        let extras = [
            MSCZExtraEntry(path: "folino/annotations.json", data: Data(#"{"a":1}"#.utf8)),
            MSCZExtraEntry(
                path: "folino/ink/1.pkdrawing",
                data: Data([0x00, 0x01, 0x02]),
                compression: .stored,
            ),
        ]
        let mscz = try MSCZWriter.write(mscxData: mscxData, extraEntries: extras)
        #expect(try MSCZReader.extraEntries(in: mscz) == extras)
    }

    @Test func readerExcludesTheTwoFixedEntries() throws {
        let mscz = try MSCZWriter.write(mscxData: mainMSCXData(), mainFileName: "renamed.mscx")
        #expect(try MSCZReader.extraEntries(in: mscz).isEmpty)
    }

    @Test func readerHonorsTheExclusionSet() throws {
        let mscz = try MSCZWriter.write(
            mscxData: mainMSCXData(),
            extraEntries: [
                MSCZExtraEntry(path: "folino/a.json", data: Data([0x01])),
                MSCZExtraEntry(path: "folino/b.json", data: Data([0x02])),
            ],
        )
        let kept = try MSCZReader.extraEntries(in: mscz, excluding: ["folino/a.json"])
        #expect(kept.map(\.path) == ["folino/b.json"])
    }

    /// The reader applies `audiosettings.json` to the `Score` and then forgets it, so a host that
    /// reads → edits → writes would drop MuseScore 4's per-part presets. Handing the entry back
    /// is what lets the host preserve it.
    @Test func readerReturnsAudioSettingsSoAHostCanPreserveIt() throws {
        let mscz = try MSCZWriter.write(
            mscxData: mainMSCXData(),
            extraEntries: [
                MSCZExtraEntry(path: "audiosettings.json", data: Data(#"{"tracks":[]}"#.utf8)),
            ],
        )
        #expect(try MSCZReader.extraEntries(in: mscz).map(\.path) == ["audiosettings.json"])
    }

    @Test func aFullRoundTripPreservesTheSidecar() throws {
        let mscxData = try mainMSCXData()
        let extras = [MSCZExtraEntry(path: "folino/annotations.json", data: Data(#"{"a":1}"#.utf8))]
        let first = try MSCZWriter.write(mscxData: mscxData, extraEntries: extras)

        let score = try MSCZReader.parse(first)
        let carried = try MSCZReader.extraEntries(in: first)
        let second = try MSCZWriter.write(
            score: score, options: MSCXEncoderOptions(), extraEntries: carried,
        )

        #expect(try MSCZReader.extraEntries(in: second) == extras)
    }

    @Test func readerRejectsBytesThatAreNotAZip() {
        do {
            _ = try MSCZReader.extraEntries(in: Data([0x00, 0x01, 0x02, 0x03]))
            Issue.record("expected throw")
        } catch let error as SheetMusicError {
            guard case let .corruptedContainer(fault) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(fault.code.hasPrefix("zip."))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
