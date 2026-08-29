import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// Consecutive voice-level `<location>` elements accumulate on ONE
/// cursor. `ReadContext::setLocation` turns a relative `Location` into
/// an absolute one against the context's *current* tick and stores it
/// (`rw/read460/readcontext.cpp`), so the shift a `<location>` applies
/// stays in force for everything that follows in the voice — it is not
/// a one-shot offset from the chord/rest cursor.
///
/// MuseScore writes exactly this shape when two tempo marks sit
/// off-beat in one bar: jog back, write the first, jog forward, write
/// the second.
@Suite("voice <location> accumulation")
struct VoiceLocationAccumulationTests {
    /// 4/4 bar: half chord (→1/2), quarter rest (→3/4), then a −1/8
    /// jog to 5/8 for the first `<Tempo>`, a +1/8 jog back to 3/4 for
    /// the second, then the quarter rest that fills 3/4→1.
    private static let twoTemposMSCX = """
    <?xml version="1.0" encoding="UTF-8"?>
    <museScore version="4.60">
      <Score>
        <Division>480</Division>
        <Part id="1">
          <Staff id="1"><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
          <Instrument id="x"><longName>X</longName></Instrument>
        </Part>
        <Staff id="1">
          <Measure>
            <voice>
              <TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>
              <Chord>
                <durationType>half</durationType>
                <Note><pitch>60</pitch><tpc>14</tpc></Note>
              </Chord>
              <Rest><durationType>quarter</durationType></Rest>
              <location><fractions>-1/8</fractions></location>
              <Tempo><tempo>0.75</tempo></Tempo>
              <location><fractions>1/8</fractions></location>
              <Tempo><tempo>1.25</tempo></Tempo>
              <Rest><durationType>quarter</durationType></Rest>
            </voice>
          </Measure>
        </Staff>
      </Score>
    </museScore>
    """

    @Test("the second <location> jogs from the first one's tick, not the chord cursor")
    func consecutiveLocationsAccumulate() throws {
        let score = try MSCXParser.parse(Data(Self.twoTemposMSCX.utf8))
        let elements = score.systemMeasures[0].elements
        #expect(elements.count == 2)
        let offsets = elements.map(\.position.offset)
        #expect(offsets == [
            Fraction(numerator: 5, denominator: 8),
            Fraction(numerator: 3, denominator: 4),
        ])
    }

    /// The decode/encode pair has to be a fixed point: whatever the
    /// first encode writes must decode back to the same ticks, or a
    /// second save silently moves the marks. `365日.mscz` shipped this
    /// exact shape and drifted 1/4 → 5/8 on the second pass.
    @Test("encoding a decoded score twice is byte-stable")
    func secondEncodePassIsStable() throws {
        let score = try MSCXParser.parse(Data(Self.twoTemposMSCX.utf8))
        let firstPass = try MSCXEncoder.encode(score)
        let reparsed = try MSCXParser.parse(firstPass)
        let secondPass = try MSCXEncoder.encode(reparsed)
        #expect(firstPass == secondPass)
        #expect(reparsed.withSource(.unknown) == score.withSource(.unknown))
    }

    /// The other half of the jog pair: a back-jog, an off-beat mark,
    /// then the forward jog that returns the cursor before the next
    /// rest. The pair cancels, so nothing reaches the voice stream —
    /// a leftover `.locationShift` here would move the rest a quarter
    /// late for every downstream walker (playback, layout, beaming).
    /// `アタタメマスカ.mscz` shipped this shape.
    private static let jogPairAroundStaffTextMSCX = """
    <?xml version="1.0" encoding="UTF-8"?>
    <museScore version="4.60">
      <Score>
        <Division>480</Division>
        <Part id="1">
          <Staff id="1"><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
          <Instrument id="x"><longName>X</longName></Instrument>
        </Part>
        <Staff id="1">
          <Measure>
            <voice>
              <TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>
              <Chord>
                <durationType>half</durationType>
                <Note><pitch>60</pitch><tpc>14</tpc></Note>
              </Chord>
              <location><fractions>-1/4</fractions></location>
              <StaffText><text>hh</text></StaffText>
              <location><fractions>1/4</fractions></location>
              <Rest><durationType>half</durationType></Rest>
            </voice>
          </Measure>
        </Staff>
      </Score>
    </museScore>
    """

    @Test("a balanced jog pair around a lifted mark leaves the voice stream alone")
    func balancedJogPairEmitsNoLocationShift() throws {
        let score = try MSCXParser.parse(Data(Self.jogPairAroundStaffTextMSCX.utf8))
        let marks = score.systemMeasures[0].elements
        #expect(marks.count == 1)
        #expect(marks.first?.position.offset == Fraction(numerator: 1, denominator: 4))
        let voice = score.parts[0].staves[0].measures[0].voices[0]
        #expect(!voice.elements.contains { if case .locationShift = $0 { true } else { false } })

        let firstPass = try MSCXEncoder.encode(score)
        let secondPass = try MSCXEncoder.encode(MSCXParser.parse(firstPass))
        #expect(firstPass == secondPass)
    }

    /// An UNbalanced jog — the mark's tick is where the voice carries
    /// on from — is the case that pins the write cursor. The encoder
    /// has to let `.locationShift` move `voiceTotal`, or it measures
    /// the lifted mark's `<location>` from the sum of durations and
    /// re-reading lands it somewhere else.
    @Test("an unencumbered .locationShift moves the encoder's cursor too")
    func unbalancedLocationShiftMovesTheWriteCursor() throws {
        let voice = Voice(elements: [
            .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14)])),
            .locationShift(delta: Fraction(numerator: -1, denominator: 4)),
            .rest(duration: .quarter),
        ])
        let tempo = PositionedSystemElement(
            position: MeasurePosition(numerator: 1, denominator: 4),
            element: .tempo(Tempo(beatsPerSecond: 2, beatNote: .quarter)),
        )
        let score = Score(
            division: 480,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "x", longName: "X"),
                staves: [Staff(measures: [Measure(voices: [voice])])],
            )],
            systemMeasures: [SystemMeasure(elements: [tempo])],
        )

        let encoded = try MSCXEncoder.encode(score)
        let reparsed = try MSCXParser.parse(encoded)
        let offsets: [Fraction] = reparsed.systemMeasures[0].elements
            .map(\.position.offset)
        #expect(offsets == [Fraction(numerator: 1, denominator: 4)])
        #expect(try MSCXEncoder.encode(reparsed) == encoded)
    }
}
