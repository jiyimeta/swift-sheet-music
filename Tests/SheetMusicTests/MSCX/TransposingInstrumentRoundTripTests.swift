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

    /// The element each generation stores the WRITTEN key in: MuseScore 3 reused `<accidental>`,
    /// MuseScore 4 introduced `<actualKey>` beside `<concertKey>` and dropped `<accidental>` from
    /// its reader entirely.
    private static func writtenKeyTag(_ version: MSCXVersion, _ key: Int) -> String {
        switch version {
        case .v2, .v3: "<accidental>\(key)</accidental>"
        case .v4: "<actualKey>\(key)</actualKey>"
        }
    }

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

    @Test("encoder writes <tpc2> and the v4 written key as <actualKey>")
    func encoderWritesTpc2AndWrittenActualKey() throws {
        let xml = try Self.encodedXML(Self.clarinetScore())
        #expect(xml.contains("<tpc2>14</tpc2>")) // written C = concert B♭ + writtenFifthsOffset(2)
        #expect(xml.contains("<transposeChromatic>-2</transposeChromatic>"))
        #expect(xml.contains("<transposeDiatonic>-1</transposeDiatonic>"))
        // MuseScore 4 writes both keys, as `<concertKey>` + `<actualKey>`
        // (`TWrite::write(const KeySig*, …)`).
        #expect(xml.contains("<concertKey>0</concertKey>"))
        #expect(xml.contains("<actualKey>2</actualKey>"))
        // `<accidental>` is MuseScore 3's spelling and is not in the 4.6 reader's element table:
        // writing the written key under that name would have Studio silently discard it and open
        // this clarinet part in C major rather than D.
        #expect(!xml.contains("<accidental>"))
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
        #expect(!xml.contains("<actualKey>"))
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
        #expect(xml.contains(Self.writtenKeyTag(version, -2)))

        let decoded = try MSCXParser.parse(
            MSCXEncoder.encode(score, options: .init(targetVersion: version)),
        )
        #expect(try Self.firstKeySignature(of: decoded).concertKey == -3)
    }

    /// The mirror of the staff-head suppression: a B♭ part in concert B♭ major (`concertKey -2`,
    /// offset `+2`) has a WRITTEN key of exactly 0. Dropping the `<KeySig>` because the written
    /// key looks like C major loses the −2 — nothing recreates the element on decode, the part
    /// comes back at concert C, and the next save writes written D. Two fifths of drift per
    /// save/load cycle, and MuseScore's compat repair only runs for `mscVersion < 420` so v4
    /// output would never be repaired. The element has to be written.
    @Test(
        "a concert key whose written form is C major is still emitted",
        arguments: [MSCXVersion.v3, .v4],
    )
    func nonZeroConcertKeyWithZeroWrittenKeySurvives(version: MSCXVersion) throws {
        var score = Score.blank(BlankScoreTemplate(
            title: "T", instrumentID: "clarinet", staves: [.init(clefType: "G")],
            concertKey: -2, measureCount: 1,
        ))
        score.parts[0].instrument.transposeDiatonic = -1
        score.parts[0].instrument.transposeChromatic = -2 // writtenFifthsOffset == 2

        let xml = try Self.encodedXML(score, targetVersion: version)
        #expect(xml.contains("<KeySig>"))
        #expect(xml.contains(Self.writtenKeyTag(version, 0)))

        let decoded = try MSCXParser.parse(
            MSCXEncoder.encode(score, options: .init(targetVersion: version)),
        )
        #expect(try Self.firstKeySignature(of: decoded).concertKey == -2)
    }

    /// A genuinely non-transposing staff head in concert C keeps the historical omission.
    @Test("a C-major staff head on a concert-pitch part is still omitted")
    func zeroKeyOnNonTransposingPartIsStillDropped() throws {
        let score = Score.blank(BlankScoreTemplate(
            title: "T", instrumentID: "piano", staves: [.init(clefType: "G")], measureCount: 1,
        ))
        #expect(try !Self.encodedXML(score).contains("<KeySig>"))
    }

    /// A hand-authored MuseScore 3 document: one B♭ clarinet part holding a written D-major
    /// `<accidental>`, with the Concert Pitch style flag set as given.
    private static func ms3Document(concertPitch: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="3.02">
          <programVersion>3.6.2</programVersion>
          <Score>
            <Division>480</Division>
            <Style>
              <concertPitch>\(concertPitch)</concertPitch>
            </Style>
            <Part>
              <Staff id="1"/>
              <Instrument id="clarinet">
                <transposeDiatonic>-1</transposeDiatonic>
                <transposeChromatic>-2</transposeChromatic>
                <Channel/>
              </Instrument>
            </Part>
            <Staff id="1">
              <Measure>
                <voice>
                  <KeySig><accidental>2</accidental></KeySig>
                  <Chord><durationType>quarter</durationType>
                    <Note><pitch>60</pitch><tpc>14</tpc></Note>
                  </Chord>
                </voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
    }

    /// MuseScore's ≤4.0 reader converts `<accidental>` to a concert key only when the Concert
    /// Pitch style flag is off (`rw/read400/tread.cpp:1228`). A v2/v3 file saved with Concert
    /// Pitch ON already stores the CONCERT key there, so the post-pass must not touch it.
    @Test(
        "the v2/v3 written-key post-pass respects <concertPitch>",
        arguments: [(concertPitch: 1, expectedKey: 2), (concertPitch: 0, expectedKey: 0)],
    )
    func concertPitchStyleGatesThePostPass(concertPitch: Int, expectedKey: Int) throws {
        let data = Data(Self.ms3Document(concertPitch: concertPitch).utf8)
        let decoded = try MSCXParser.parse(data)
        #expect(try Self.firstKeySignature(of: decoded).concertKey == expectedKey)
    }
}
