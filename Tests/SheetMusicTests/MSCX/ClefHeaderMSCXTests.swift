import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

/// The clef a staff opens with is MuseScore's HEADER clef, and since 4.1 MuseScore decides that from the tag alone:
/// `<isHeader>1</isHeader>` puts a `<Clef>` in the `HeaderClef` segment, anything else in a `Clef` segment
/// (`rw/read460/measureread.cpp`; read400's `measurerw.cpp` keeps the older guess by position for files before 4.1).
/// A `Clef` segment sorts after the key and time signatures, so an opening clef written without the tag opened in
/// MuseScore as the staff's default clef followed by a clef change after the meter.
@Suite("Header clef in MSCX")
struct ClefHeaderMSCXTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    /// The top-level `<Staff>` that holds the measures, as opposed to the one inside `<Part>` declaring it.
    private static func staffBody(_ data: Data) throws -> XMLTreeNode {
        let score = try #require(XMLTreeParser.parse(data).first("Score"))
        return try #require(score.all("Staff").first { !$0.all("Measure").isEmpty })
    }

    /// Each bar's voice-0 clefs as `type` or `type/isHeader` — the two things this suite is about.
    private static func clefSummary(_ data: Data) throws -> [[String]] {
        try staffBody(data).all("Measure").map { measure in
            (measure.first("voice")?.all("Clef") ?? []).map { clef in
                [clef.first("concertClefType")?.text, clef.first("isHeader")?.text]
                    .compactMap(\.self)
                    .joined(separator: "/")
            }
        }
    }

    /// Replacing the opening clef the way an editor does — `SetClef` before the bar's first rest, under a key and a
    /// meter — and changing it again mid-bar and at the head of the next bar.
    private static func scoreWithThreeClefs() throws -> Score {
        var score = EditingFixtures.twoMeasuresOfQuarterRests(key: 3) // m0: [ks, ts, r, r, r, r]; m1: [r, r, r, r]
        _ = try SetClef(before: slot(1, 0), clef: .bass).apply(to: &score)
        _ = try SetClef(before: slot(0, 3), clef: .alto).apply(to: &score)
        _ = try SetClef(before: slot(0, 2), clef: NotatedClef(rawType: "G8vb")).apply(to: &score)
        return score
    }

    @Test("the clef a staff opens with is tagged as the header; a change mid-bar or at a later bar is not")
    func onlyTheOpeningClefIsAHeader() throws {
        let data = try MSCXEncoder.encode(Self.scoreWithThreeClefs())
        #expect(try Self.clefSummary(data) == [["G8vb/1", "C3"], ["F"]])
    }

    /// The tag is derived from the clef's place, so reading it back must not also keep it as preserved markup: a clef
    /// copied out of the first bar would carry it along and declare a header in the middle of the score.
    ///
    /// Byte identity is checked from the second save on, as the idempotency gate does: the first read assigns the
    /// fixture identities it was built without.
    @Test("a header clef reads back without its tag and saves the same tags again")
    func headerTagRoundTrips() throws {
        let reopened = try MSCXParser.parse(MSCXEncoder.encode(Self.scoreWithThreeClefs()))
        guard case let .clef(clef) = reopened.parts[0].staves[0].measures[0].voices[0].elements.values[0] else {
            Issue.record("bar 0 no longer opens with its clef")
            return
        }
        #expect(clef.preservedMarkup.isEmpty)
        let second = try MSCXEncoder.encode(reopened)
        #expect(try Self.clefSummary(second) == [["G8vb/1", "C3"], ["F"]])
        #expect(try MSCXEncoder.encode(MSCXParser.parse(second)) == second)
    }

    /// A MuseScore 3 file has no such tag — its reader takes a clef at a bar's first tick, ahead of any key or time
    /// signature there, as the header — so a version 3 save leaves it out and relies on the order alone.
    @Test("a version 3 save writes no header tag and keeps the clef ahead of the signatures")
    func version3RelyOnPosition() throws {
        let data = try MSCXEncoder.encode(Self.scoreWithThreeClefs(), options: MSCXEncoderOptions(targetVersion: .v3))
        #expect(try Self.clefSummary(data) == [["G8vb", "C3"], ["F"]])
        let firstVoice = try #require(Self.staffBody(data).first("Measure")?.first("voice"))
        #expect(firstVoice.children.prefix(3).map(\.name) == ["Clef", "KeySig", "TimeSig"])
    }
}
