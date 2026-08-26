import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

@Suite("Transposing instrument MSCX round-trip")
struct TransposingInstrumentRoundTripTests {
    /// A one-part, one-measure score whose instrument is a B♭ clarinet holding concert B♭4
    /// (pitch 70, tpc 12) in concert C major.
    private static func clarinetScore() -> Score {
        var score = Score.blank(BlankScoreTemplate(
            title: "T", instrumentID: "clarinet", staves: [.init(clefType: "G")], measureCount: 1,
        ))
        score.parts[0].instrument.transposeDiatonic = -1
        score.parts[0].instrument.transposeChromatic = -2
        score.parts[0].staves[0].measures[0].voices[0].elements[2] =
            .chord(Chord(duration: .whole, notes: [Note(pitch: 70, tpc: 12)]))
        return score
    }

    private static func encodedXML(
        _ score: Score, targetVersion: MSCXVersion = .v4,
    ) throws -> String {
        let bytes = try MSCXEncoder.encode(
            score, options: .init(targetVersion: targetVersion),
        )
        return try #require(String(bytes: bytes, encoding: .utf8))
    }

    /// The first voice element of the score's only staff, required to be a key signature.
    private static func firstKeySignature(of score: Score) throws -> KeySignature {
        let element = score.parts[0].staves[0].measures[0].voices[0].elements[0]
        guard case let .keySignature(key) = element else {
            Issue.record("expected a key signature at the staff head, found \(element)")
            throw KeySignatureMissing()
        }
        return key
    }

    private struct KeySignatureMissing: Error {}

    @Test("transpose tags survive encode → parse")
    func transposeTagsRoundTrip() throws {
        let score = Self.clarinetScore()
        let data = try MSCXEncoder.encode(score)
        let decoded = try MSCXParser.parse(data)
        #expect(decoded.parts[0].instrument.transposeDiatonic == -1)
        #expect(decoded.parts[0].instrument.transposeChromatic == -2)
        #expect(decoded.parts[0].staves[0].measures[0].voices[0].elements[2]
            == score.parts[0].staves[0].measures[0].voices[0].elements[2])
    }

    @Test("encoder writes <tpc2> and the written key on a transposing part")
    func encoderWritesTpc2AndWrittenAccidental() throws {
        let xml = try Self.encodedXML(Self.clarinetScore())
        #expect(xml.contains("<tpc2>14</tpc2>")) // written C = concert B♭ + writtenFifthsOffset(2)
        #expect(xml.contains("<transposeChromatic>-2</transposeChromatic>"))
        #expect(xml.contains("<transposeDiatonic>-1</transposeDiatonic>"))
        // MuseScore 4 writes both the concert key and the written one.
        #expect(xml.contains("<concertKey>0</concertKey>"))
        #expect(xml.contains("<accidental>2</accidental>"))
    }

    @Test("non-transposing parts keep their existing byte shape")
    func nonTransposingPartIsUnchanged() throws {
        var score = Self.clarinetScore()
        score.parts[0].instrument.transposeDiatonic = 0
        score.parts[0].instrument.transposeChromatic = 0
        let xml = try Self.encodedXML(score)
        #expect(!xml.contains("<tpc2>"))
        #expect(!xml.contains("<transposeChromatic>"))
        #expect(!xml.contains("<transposeDiatonic>"))
        #expect(!xml.contains("<accidental>"))
    }

    /// v2/v3 files write `<accidental>` = the WRITTEN key on transposing parts; the decoder must
    /// convert it back to concert.
    @Test("v3 <accidental> is read back as a concert key")
    func v3AccidentalFallbackConvertsWrittenToConcert() throws {
        let score = Self.clarinetScore() // concert C major on a B♭ instrument
        let data = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
        let xml = try #require(String(bytes: data, encoding: .utf8))
        #expect(xml.contains("<accidental>2</accidental>")) // written D major
        #expect(!xml.contains("<concertKey>"))

        let decoded = try MSCXParser.parse(data)
        #expect(try Self.firstKeySignature(of: decoded).concertKey == 0) // back to concert
    }

    /// A written key that lands outside `[-7, +7]` must be respelled rather than emitted as an
    /// unwritable signature: concert C♯ major (+7) on an alto sax (offset +3) is +10, written as
    /// −2 (B♭ major). The respelling is deliberately not invertible — reading it back yields the
    /// enharmonic equivalent D♭ major (−5), exactly as MuseScore itself would.
    @Test("a written key outside [-7, +7] is respelled on the way out and on the way back")
    func writtenKeyIsRespelledInBothDirections() throws {
        var score = Score.blank(BlankScoreTemplate(
            title: "T", instrumentID: "alto-sax", staves: [.init(clefType: "G")],
            concertKey: 7, measureCount: 1,
        ))
        score.parts[0].instrument.transposeDiatonic = -5
        score.parts[0].instrument.transposeChromatic = -9 // writtenFifthsOffset == 3

        let xml = try Self.encodedXML(score, targetVersion: .v3)
        #expect(xml.contains("<accidental>-2</accidental>")) // respelled(7 + 3) == -2

        let decoded = try MSCXParser.parse(
            MSCXEncoder.encode(score, options: .init(targetVersion: .v3)),
        )
        // respelled(-2 - 3): D♭ major, C♯ major's enharmonic twin.
        #expect(try Self.firstKeySignature(of: decoded).concertKey == -5)
    }

    /// A key that stays inside the writable range round-trips exactly, on both wire generations.
    @Test("an in-range written key round-trips exactly", arguments: [MSCXVersion.v3, .v4])
    func inRangeWrittenKeyRoundTrips(version: MSCXVersion) throws {
        var score = Score.blank(BlankScoreTemplate(
            title: "T", instrumentID: "horn", staves: [.init(clefType: "G")],
            concertKey: -3, measureCount: 1,
        ))
        score.parts[0].instrument.transposeDiatonic = -4
        score.parts[0].instrument.transposeChromatic = -7 // writtenFifthsOffset == 1

        let xml = try Self.encodedXML(score, targetVersion: version)
        #expect(xml.contains("<accidental>-2</accidental>"))

        let decoded = try MSCXParser.parse(
            MSCXEncoder.encode(score, options: .init(targetVersion: version)),
        )
        #expect(try Self.firstKeySignature(of: decoded).concertKey == -3)
    }
}
