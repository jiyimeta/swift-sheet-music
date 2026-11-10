import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// MuseScore's per-ChordRest `<BeamMode>` — the beam edits a user makes with the beam palette ("start beam",
/// "middle of beam", "no beam", …), and what MuseScore's MusicXML import writes on every note from `<beam>`. Read as
/// `TRead::readProperties(ChordRest*)` reads it (`rw/read460/tread.cpp:2584`, `TConv::fromXml(…, AUTO)`), written as
/// `TWrite::writeProperties(const ChordRest*)` writes it (`rw/write/twrite.cpp:1098-1104`: a chord unless `auto`, a
/// rest unless `no`, before `<small>`), and honored the way `BeamLayout::createBeams` honors it.
@Suite("Chord / Rest <BeamMode>")
struct BeamModeTests {
    private static let fourFour = TimeSignature(numerator: 4, denominator: 4)

    private static func measureXML(_ body: String, version: String = "4.60") -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="\(version)"><Score><Division>480</Division>
        <Part id="1"><Staff><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
        <Instrument id="piano"><longName>Piano</longName></Instrument></Part>
        <Staff id="1"><Measure><voice>
        <TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>
        \(body)
        </voice></Measure></Staff>
        </Score></museScore>
        """
        return Data(xml.utf8)
    }

    private static func eighth(_ mode: String? = nil) -> String {
        let tag = mode.map { "<BeamMode>\($0)</BeamMode>" } ?? ""
        return "<Chord>\(tag)<durationType>eighth</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>"
    }

    private static func chords(_ score: Score) -> [Chord] {
        score.parts[0].staves[0].measures[0].voices[0].elements.compactMap {
            if case let .chord(chord) = $0 { chord } else { nil }
        }
    }

    // MARK: - Decode / encode

    @Test("every MuseScore BeamMode token reads to its case; absent and unknown read as auto")
    func decodesEveryToken() throws {
        let tokens = ["auto", "no", "begin", "mid", "end", "begin16", "begin32", "bogus"]
        let body = tokens.map { Self.eighth($0) }.joined() + Self.eighth()
        let modes = try Self.chords(MSCXParser.parse(Self.measureXML(body))).map(\.beamMode)
        #expect(modes == [.auto, .none, .begin, .mid, .end, .begin16, .begin32, .auto, .auto])
    }

    /// MuseScore 2.x through 4.0 named the two secondary-beam breaks `begin32` / `begin64`; 4.1 renamed them `begin16`
    /// / `begin32` and renames the old tokens when it reads an older file (`rw/read400/tread.cpp:2428-2437`).
    /// Only the two old names are renamed; any other token — `begin16` included — goes through as it is, as in
    /// MuseScore's reader.
    @Test("a pre-4.10 file's begin32 / begin64 read as begin16 / begin32", arguments: ["3.02", "4.00"])
    func legacySecondaryBeamTokens(version: String) throws {
        let body = Self.eighth("begin32") + Self.eighth("begin64") + Self.eighth("begin16") + Self.eighth("mid")
        let modes = try Self.chords(MSCXParser.parse(Self.measureXML(body, version: version))).map(\.beamMode)
        #expect(modes == [.begin16, .begin32, .begin16, .mid])
    }

    @Test("the 3.x output writes the secondary-beam breaks by their older tokens, and reads them back")
    func legacyOutputTokens() throws {
        let original = try MSCXParser.parse(Self.measureXML(Self.eighth("begin16") + Self.eighth("begin32")))
        let v3 = try #require(String(
            bytes: MSCXEncoder.encode(original, options: MSCXEncoderOptions(targetVersion: .v3)), encoding: .utf8,
        ))
        #expect(v3.contains("<BeamMode>begin32</BeamMode>") && v3.contains("<BeamMode>begin64</BeamMode>"))
        #expect(try Self.chords(MSCXParser.parse(Data(v3.utf8))).map(\.beamMode) == [.begin16, .begin32])
        let v4 = try #require(String(bytes: MSCXEncoder.encode(original), encoding: .utf8))
        #expect(v4.contains("<BeamMode>begin16</BeamMode>") && v4.contains("<BeamMode>begin32</BeamMode>"))
    }

    @Test("a rest reads its BeamMode too, and is no longer preserved markup")
    func restReadsBeamMode() throws {
        let body = "<Rest><BeamMode>mid</BeamMode><durationType>eighth</durationType></Rest>" + Self.eighth()
        let rest = try #require(Self.chords(MSCXParser.parse(Self.measureXML(body))).first)
        #expect(rest.notes.isEmpty)
        #expect(rest.beamMode == .mid)
        #expect(!rest.preservedMarkup.map(\.name).contains("BeamMode"))
    }

    @Test("a chord writes its BeamMode unless auto, before <durationType>, and reads it back")
    func chordRoundTrips() throws {
        let original = try MSCXParser.parse(Self.measureXML(Self.eighth("no") + Self.eighth()))
        let text = try #require(String(bytes: MSCXEncoder.encode(original), encoding: .utf8))
        #expect(text.components(separatedBy: "<BeamMode>").count == 2)
        let mode = try #require(text.range(of: "<BeamMode>no</BeamMode>"))
        let duration = try #require(text.range(of: "<durationType>eighth</durationType>"))
        #expect(mode.lowerBound < duration.lowerBound)
        let reread = try Self.chords(MSCXParser.parse(Data(text.utf8))).map(\.beamMode)
        #expect(reread == [.none, .auto])
    }

    /// A rest's default is `no` in MuseScore, and `auto` behaves the same on a rest (`Groups::actualBeamMode`), so
    /// neither is written; the modes that beam over the rest are.
    @Test("a rest writes BeamMode only when it beams over the rest")
    func restWritesOnlyBeamingModes() throws {
        let body = "<Rest><BeamMode>mid</BeamMode><durationType>eighth</durationType></Rest>"
            + "<Rest><BeamMode>no</BeamMode><durationType>eighth</durationType></Rest>"
            + "<Rest><BeamMode>auto</BeamMode><durationType>eighth</durationType></Rest>"
            + "<Rest><durationType>eighth</durationType></Rest>" + Self.eighth() + Self.eighth()
        let original = try MSCXParser.parse(Self.measureXML(body))
        let text = try #require(String(bytes: MSCXEncoder.encode(original), encoding: .utf8))
        #expect(text.components(separatedBy: "<BeamMode>").count == 2)
        #expect(text.contains("<BeamMode>mid</BeamMode>"))
    }

    // MARK: - Grouping

    private func eighthChord(_ mode: BeamMode = .auto) -> VoiceElement {
        var chord = Chord(duration: .eighth, notes: [Note(pitch: 60, tpc: 14)])
        chord.beamMode = mode
        return .chord(chord)
    }

    private func sixteenthChord(_ mode: BeamMode = .auto) -> VoiceElement {
        var chord = Chord(duration: .sixteenth, notes: [Note(pitch: 60, tpc: 14)])
        chord.beamMode = mode
        return .chord(chord)
    }

    private func eighthRest(_ mode: BeamMode = .auto) -> VoiceElement {
        var rest = Chord(duration: .eighth, notes: [])
        rest.beamMode = mode
        return .chord(rest)
    }

    private func groups(_ elements: [VoiceElement]) -> [[Int]] {
        BeamGrouping.groups(
            voice: Voice(elements: [.timeSignature(Self.fourFour)] + elements),
            timeSignature: Self.fourFour, division: 480,
        ).map(\.memberIndices)
    }

    @Test("auto everywhere keeps the default grouping: four eighths are one beam")
    func autoKeepsDefault() {
        #expect(groups([eighthChord(), eighthChord(), eighthChord(), eighthChord()]) == [[1, 2, 3, 4]])
    }

    @Test("begin starts a new beam where the default would have continued")
    func beginBreaks() {
        #expect(groups([eighthChord(), eighthChord(), eighthChord(.begin), eighthChord()]) == [[1, 2], [3, 4]])
    }

    @Test("no leaves the chord unbeamed and ends the beam it would have joined")
    func noneUnbeams() {
        #expect(groups([eighthChord(), eighthChord(.none), eighthChord(), eighthChord()]) == [[3, 4]])
    }

    @Test("end closes the beam after the chord")
    func endCloses() {
        #expect(groups([eighthChord(), eighthChord(.end), eighthChord(), eighthChord()]) == [[1, 2], [3, 4]])
    }

    @Test("mid continues across the half-bar boundary where the default breaks")
    func midJoinsAcrossTheHalfBar() {
        let plain = (0 ..< 8).map { _ in eighthChord() }
        #expect(groups(plain) == [[1, 2, 3, 4], [5, 6, 7, 8]])
        var joined = plain
        joined[4] = eighthChord(.mid)
        #expect(groups(joined) == [[1, 2, 3, 4, 5, 6, 7, 8]])
    }

    @Test("mid continues sixteenths across the beat where the default breaks every beat")
    func midJoinsSixteenthsAcrossTheBeat() {
        var elements = (0 ..< 8).map { _ in sixteenthChord() }
        #expect(groups(elements) == [[1, 2, 3, 4], [5, 6, 7, 8]])
        elements[4] = sixteenthChord(.mid)
        #expect(groups(elements) == [[1, 2, 3, 4, 5, 6, 7, 8]])
    }

    /// `BeamLayout::createBeams`: "Rests of any duration can be beamed over, if required" — a rest set to `mid` sits
    /// inside the beam, so the chords on either side share it. The rest is no member (it has no stem to meet the bar).
    @Test("a rest set to mid is beamed over; an auto rest still breaks the beam")
    func restBeamedOver() {
        #expect(groups([eighthChord(), eighthRest(.mid), eighthChord(), eighthChord()]) == [[1, 3, 4]])
        #expect(groups([eighthChord(), eighthRest(), eighthChord(), eighthChord()]) == [[3, 4]])
    }

    @Test("a quarter is never beamed whatever its mode says")
    func quarterIgnoresMode() {
        var quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        quarter.beamMode = .mid
        #expect(groups([.chord(quarter), eighthChord(), eighthChord()]) == [[2, 3]])
    }
}
