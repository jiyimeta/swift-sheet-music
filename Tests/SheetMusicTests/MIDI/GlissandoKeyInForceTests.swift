@testable import SheetMusicCore
import SheetMusicFoundation
@testable import SheetMusicMIDI
import Testing

/// Which key a diatonic glissando slides through: the one in force where it ends, whichever bar and voice the
/// signature stands in. The expected scales are MuseScore 4.7's (its MIDI export of the same bars), except where a
/// test says otherwise.
@Suite("A diatonic glissando's key")
struct GlissandoKeyInForceTests {
    private static let division = 480
    private static let cMajor = [60, 62, 64, 65, 67, 69, 71, 72]
    private static let eFlatMajor = [60, 62, 63, 65, 67, 68, 70, 72]
    private static let gMajor = [60, 62, 64, 66, 67, 69, 71, 72]
    private static let rest = VoiceElement.chord(Chord(duration: .measure, notes: ChordNotes([])))

    private static func slide(_ duration: NoteDuration = .half) -> VoiceElement {
        .chord(Chord(duration: duration, notes: [Note(pitch: 60, tpc: 14, glissando: Glissando(style: .diatonic))]))
    }

    private static func plain(_ pitch: Int, _ duration: NoteDuration = .half) -> VoiceElement {
        .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: 14)]))
    }

    private static func key(_ concertKey: Int) -> VoiceElement {
        .keySignature(KeySignature(concertKey: concertKey))
    }

    /// A bar that slides C4 to C5, after `leading`.
    private static func bar(_ leading: VoiceElement...) -> Measure {
        Measure(voices: [Voice(elements: leading + [slide(), plain(72)])])
    }

    /// What each played bar sounds, in playback order.
    private static func played(_ measures: [Measure]) throws -> [[Int]] {
        let instrument = Instrument(id: "piano", articulations: [InstrumentArticulation()])
        let part = Part(id: "P1", instrument: instrument, staves: [Staff(measures: measures)])
        let file = try MidiRenderer.renderForPlayback(score: Score(division: division, parts: [part]))
        var bars: [Int: [(tick: Int, pitch: Int)]] = [:]
        for event in file.tracks.flatMap(\.events) {
            guard case let .noteOn(_, pitch, velocity) = event.event, velocity > 0 else { continue }
            bars[event.tick / (4 * division), default: []].append((event.tick, pitch))
        }
        return bars.keys.sorted().map { index in
            (bars[index] ?? []).sorted { $0.tick < $1.tick }.map(\.pitch)
        }
    }

    @Test("a signature in an earlier bar stays in force")
    func earlierBar() throws {
        let bars = try Self.played([Self.bar(Self.key(0)), Self.bar(Self.key(-3)), Self.bar(), Self.bar(Self.key(1))])
        #expect(bars == [Self.cMajor, Self.eFlatMajor, Self.eFlatMajor, Self.gMajor])
    }

    @Test("a signature written in voice 1 reaches voice 2, in its own bar and after it")
    func otherVoice() throws {
        let slides = Voice(elements: [Self.slide(), Self.plain(72)])
        let bars = try Self.played([
            Measure(voices: [Voice(elements: [Self.key(0), Self.rest]), slides]),
            Measure(voices: [Voice(elements: [Self.key(-3), Self.rest]), slides]),
            Measure(voices: [Voice(elements: [Self.rest]), slides]),
        ])
        #expect(bars == [Self.cMajor, Self.eFlatMajor, Self.eFlatMajor])
    }

    @Test("a bar before the score's first signature is in C")
    func beforeTheFirst() throws {
        #expect(try Self.played([Self.bar(), Self.bar(Self.key(-3))]) == [Self.cMajor, Self.eFlatMajor])
    }

    /// MuseScore 4.7 reads the bar's opening key here (`Measure::findAccidental` walks chords and rests only), so it
    /// slides in G; a change inside the bar takes effect where it stands.
    @Test("a change inside the bar takes effect where it stands, and lasts")
    func insideTheBar() throws {
        let bars = try Self.played([
            Measure(voices: [Voice(elements: [
                Self.key(1), Self.slide(.quarter), Self.plain(72, .quarter), Self.key(-3), Self.slide(.quarter),
                Self.plain(72, .quarter),
            ])]),
            Self.bar(),
        ])
        #expect(bars == [Self.gMajor + Self.eFlatMajor, Self.eFlatMajor])
    }

    @Test("a change inside the bar reaches the other voice from its own tick")
    func insideTheBarOtherVoice() throws {
        let bars = try Self.played([Measure(voices: [
            Voice(elements: [
                Self.key(1), .chord(Chord(duration: .half, notes: ChordNotes([]))), Self.key(-3),
                .chord(Chord(duration: .half, notes: ChordNotes([]))),
            ]),
            Voice(elements: [
                Self.slide(.quarter), Self.plain(72, .quarter), Self.slide(.quarter), Self.plain(72, .quarter),
            ]),
        ])])
        #expect(bars == [Self.gMajor + Self.eFlatMajor])
    }

    /// `chromaticPitchSteps` (`engraving/dom/utils.cpp:807`) reads the accidentals of the bar the glissando's END
    /// note is in.
    @Test("a slide over a barline takes the key of the bar it ends in")
    func acrossABarline() throws {
        let bars = try Self.played([
            Measure(voices: [Voice(elements: [Self.key(-3), Self.plain(60), Self.slide()])]),
            Measure(voices: [Voice(elements: [Self.key(1), Self.plain(72), Self.plain(60)])]),
        ])
        #expect(bars == [[60] + Self.gMajor.dropLast(), [72, 60]])
    }

    @Test("each pass of a repeat, and each ending, plays its own bars' keys")
    func repeatsAndVoltas() throws {
        func ending(_ number: Int) -> VoiceElement {
            .spanner(Spanner(kind: .volta, rawType: "Volta", nextMeasuresOffset: 1, voltaEndings: [number]))
        }
        var first = Self.bar(Self.key(0))
        first.startRepeat = true
        var back = Self.bar(ending(1))
        back.endRepeatCount = 2
        let bars = try Self.played([first, Self.bar(Self.key(-3)), back, Self.bar(ending(2), Self.key(1)), Self.bar()])
        #expect(bars == [
            Self.cMajor, Self.eFlatMajor, Self.eFlatMajor,
            Self.cMajor, Self.eFlatMajor, Self.gMajor, Self.gMajor,
        ])
    }

    @Test("a jump back plays in the key of where it lands")
    func jump() throws {
        var last = Self.bar()
        last.jumps = [Jump(jumpTo: "start", playUntil: "end", text: "D.C.")]
        let bars = try Self.played([Self.bar(Self.key(0)), Self.bar(), Self.bar(Self.key(-3)), last])
        let once = [Self.cMajor, Self.cMajor, Self.eFlatMajor, Self.eFlatMajor]
        #expect(bars == once + once)
    }

    @Test("a measure repeat plays the bar it repeats, in that bar's key")
    func measureRepeat() throws {
        let sign = VoiceElement.measureRepeat(MeasureRepeat(numMeasures: 1, duration: .measure))
        func repeated(_ leading: VoiceElement...) -> Measure {
            Measure(voices: [Voice(elements: leading + [sign])], measureRepeatCount: 1)
        }
        let bars = try Self.played([
            Self.bar(Self.key(0)), Self.bar(Self.key(-3)), repeated(), repeated(Self.key(1)),
        ])
        #expect(bars == [Self.cMajor, Self.eFlatMajor, Self.eFlatMajor, Self.eFlatMajor])
    }
}
