@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// The sound timeline: the instrument timeline plus the part's play techniques.
@Suite("Sound timeline")
struct SoundTimelineTests {
    private static func summary(_ points: [Score.SoundPoint]) -> [String] {
        points.map { "\($0.measureIndex):\($0.instrument.channel.program):\($0.reusesPoint.map(String.init) ?? "-")" }
    }

    @Test("a score without techniques has exactly its instrument timeline")
    func withoutTechniques() throws {
        for name in ["instrument-change", "w5-capo-playback", "w5-fingering-staves"] {
            let score = try AnnotationFixtures.load(name)
            for part in score.parts.indices {
                let instruments = score.instrumentTimeline(forPart: part)
                let sounds = score.soundTimeline(forPart: part)
                #expect(sounds.map(\.instrument) == instruments.map(\.instrument), "\(name)")
                #expect(sounds.map(\.measureIndex) == instruments.map(\.measureIndex), "\(name)")
                #expect(sounds.map(\.position) == instruments.map(\.position), "\(name)")
                #expect(sounds.allSatisfy { $0.reusesPoint == nil && $0.flavourSource == nil }, "\(name)")
            }
        }
    }

    @Test("pizzicato, tremolo and arco select the violin's own channels and return to the first")
    func violinChannels() throws {
        let score = try AnnotationFixtures.load("w5-play-techniques")
        let points = score.soundTimeline(forPart: 0)
        // seed, pizz @1, arco @2 (the seed's sound again), tremolo @3; the muted-flag pizz @4 is nothing; arco @5.
        #expect(Self.summary(points) == ["0:40:-", "1:45:-", "2:40:0", "3:44:-", "5:40:0"])
        try #require(points.count == 5)
        #expect(points[1].instrument.channels.map(\.name) == ["pizzicato"])
        #expect(points[1].instrument.trackName == "Pizzicato")
        #expect(points[3].instrument.trackName == "Tremolo")
        #expect(points[2].instrument == points[0].instrument)
        // The violin's own pizzicato and tremolo channels sound them: no channel of their own.
        #expect(points[1].flavourSource == Score.SoundPoint.FlavourSource(point: 0, flavour: 1))
        #expect(points[3].flavourSource == Score.SoundPoint.FlavourSource(point: 0, flavour: 2))
    }

    @Test("a guitar with one channel gets MuseScore's General MIDI sounds, bank 0")
    func guitarGeneralMIDI() throws {
        let score = try AnnotationFixtures.load("w5-play-techniques")
        let points = score.soundTimeline(forPart: 1)
        // seed 25; mute 28; natural; harmonics 31; (nothing at 4); open has no sound of its own: the first again.
        #expect(Self.summary(points) == ["0:25:-", "1:28:-", "2:25:0", "3:31:-", "5:25:0"])
        try #require(points.count == 5)
        #expect(points[1].instrument.channel.bank == 0)
        #expect(points[1].instrument.channel.midiChannel == nil)
        #expect(points[1].flavourSource == nil)
    }

    @Test("resolve: named channel, General MIDI table, or keep")
    func resolution() {
        let violin = Instrument(id: "violin", channels: [
            InstrumentChannel(program: 40), InstrumentChannel(name: "pizzicato", program: 45),
        ])
        #expect(PlayTechniqueSound.resolve(.pizzicato, for: violin) == .channel(violin.channels[1]))
        #expect(PlayTechniqueSound.resolve(.tremolo, for: violin) == .keep)
        #expect(PlayTechniqueSound.resolve(.natural, for: violin) == .keep)
        let strings = Instrument(id: "violins", channels: [InstrumentChannel(program: 48)])
        #expect(PlayTechniqueSound.resolve(.pizzicato, for: strings) == .generalMIDI(program: 45))
        #expect(PlayTechniqueSound.resolve(.tremolo, for: strings) == .generalMIDI(program: 44))
        #expect(PlayTechniqueSound.resolve(.mute, for: strings) == .generalMIDI(program: 49))
        let trumpet = Instrument(id: "trumpet", channels: [InstrumentChannel(program: 56)])
        #expect(PlayTechniqueSound.resolve(.mute, for: trumpet) == .generalMIDI(program: 59))
        let electric = Instrument(id: "electric-guitar", channels: [InstrumentChannel(program: 27)])
        #expect(PlayTechniqueSound.resolve(.distortion, for: electric) == .generalMIDI(program: 30))
        #expect(PlayTechniqueSound.resolve(.overdrive, for: electric) == .generalMIDI(program: 29))
        let acoustic = Instrument(id: "guitar-nylon", channels: [InstrumentChannel(program: 24)])
        #expect(PlayTechniqueSound.resolve(.harmonics, for: acoustic) == .generalMIDI(program: 31))
        #expect(PlayTechniqueSound.resolve(.distortion, for: acoustic) == .keep)
        // A single violin has no tremolo sound in MuseScore's table; a drum kit has no technique at all.
        let single = Instrument(id: "violin", channels: [InstrumentChannel(program: 40)])
        #expect(PlayTechniqueSound.resolve(.tremolo, for: single) == .keep)
        let kit = Instrument(id: "drumset", channels: [InstrumentChannel(program: 0)], useDrumset: true)
        #expect(PlayTechniqueSound.resolve(.pizzicato, for: kit) == .keep)
    }

    /// MuseScore's ids, `share/instruments/instruments.xml`: a family is a whole id or a whole hyphen segment, so a
    /// contrabassoon is not a contrabass and steel drums tuned like a guitar are not a guitar.
    @Test("a family is matched by whole ids and segments, not by prefix")
    func familiesByIDSegment() {
        func resolve(_ technique: PlayingTechnique, _ id: String) -> PlayTechniqueSound.Outcome {
            PlayTechniqueSound.resolve(technique, for: Instrument(id: id, channels: [InstrumentChannel(program: 0)]))
        }
        for id in [
            "contrabassoon", "contrabass-clarinet", "contrabass-flute", "cornett", "cornettino", "tubaphone",
            "cello-steel-drums", "guitar-steel-drums",
        ] {
            #expect(resolve(.pizzicato, id) == .keep, "\(id)")
            #expect(resolve(.mute, id) == .keep, "\(id)")
        }
        // Reeds, and brass with sounds of their own outside MuseScore's brass section.
        for id in ["english-horn", "basset-horn", "bb-cornet", "flugelhorn", "euphonium-bugle", "mellophon-bugle"] {
            #expect(resolve(.mute, id) == .keep, "\(id)")
        }
        for id in [
            "contrabass-trombone", "piccolo-trumpet", "f-tuba", "wagner-tuba", "eb-horn", "baritone-horn", "bugle",
            "euphonium",
        ] {
            #expect(resolve(.mute, id) == .generalMIDI(program: 59), "\(id)")
        }
        for id in ["violins", "violas", "violoncellos", "contrabasses", "viola-da-gamba", "violone", "treble-viol"] {
            #expect(resolve(.pizzicato, id) == .generalMIDI(program: 45), "\(id)")
            #expect(resolve(.tremolo, id) == .generalMIDI(program: 44), "\(id)")
            #expect(resolve(.mute, id) == .generalMIDI(program: 49), "\(id)")
        }
        // A solo has its pizzicato only; the strings group has no tremolo row.
        #expect(resolve(.pizzicato, "double-bass") == .generalMIDI(program: 45))
        #expect(resolve(.tremolo, "double-bass") == .keep)
        #expect(resolve(.mute, "violoncello") == .keep)
        #expect(resolve(.tremolo, "strings") == .keep)
        #expect(resolve(.mute, "strings") == .generalMIDI(program: 49))
        #expect(resolve(.pizzicato, "octobass") == .generalMIDI(program: 45))
        #expect(resolve(.tremolo, "octobass") == .keep)
        // Deliberately not MuseScore's last strings rule: a harp or a mandolin is no string ensemble.
        #expect(resolve(.pizzicato, "harp") == .keep)
        #expect(resolve(.mute, "mandolin") == .keep)
    }

    @Test("detaché, vibrato, legato and the handbell techniques sound as before")
    func soundlessTechniques() {
        let violin = Instrument(id: "violin", channels: [InstrumentChannel(program: 40)])
        for technique in [
            PlayingTechnique.detache,
            .martele,
            .colLegno,
            .sulPonticello,
            .sulTasto,
            .vibrato,
            .legato,
            .handbellsSwing,
            .handbellsR,
            .other("undefined"),
        ] {
            #expect(PlayTechniqueSound.resolve(technique, for: violin) == .keep, "\(technique)")
        }
    }

    @Test("techniques listed out of time order in a bar sound in time order")
    func outOfOrderLane() {
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        func element(_ text: String, _ technique: PlayingTechnique, at position: MeasurePosition)
            -> PositionedSystemElement
        {
            var staffText = StaffText(text: text)
            staffText.annotation = .playTechnique(technique, playsBack: true)
            return PositionedSystemElement(position: position, element: .staffText(staffText), originalStaff: address)
        }
        // "arco" on beat 3 is listed before "pizz." on beat 1.
        let lane = [SystemMeasure(elements: [
            element("arco", .natural, at: MeasurePosition(numerator: 1, denominator: 2)),
            element("pizz.", .pizzicato, at: .start),
        ])]
        let violin = Instrument(id: "violin", channels: [
            InstrumentChannel(program: 40), InstrumentChannel(name: "pizzicato", program: 45),
        ])
        let measure = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: ChordNotes([Note(pitch: 69, tpc: 17)]))),
        ])])
        let score = Score(division: 480, parts: [Part(
            id: "P1", instrument: violin, staves: [Staff(lineCount: 5, measures: [measure])],
        )], systemMeasures: IdentifiedArray(lane))
        let points = score.soundTimeline(forPart: 0)
        // The seed, pizzicato from beat 1, back to the seed's sound on beat 3.
        #expect(Self.summary(points) == ["0:40:-", "0:45:-", "0:40:0"])
        #expect(points.map(\.position) == [.start, .start, MeasurePosition(numerator: 1, denominator: 2)])
    }

    @Test("a technique's point names the instrument point it modifies; an instrument point names none")
    func basePoints() throws {
        let score = try AnnotationFixtures.load("w5-play-techniques")
        let points = score.soundTimeline(forPart: 1)
        #expect(points.map(\.basePoint) == [nil, 0, 0, 0, 0])
    }

    @Test("ten alternations of pizzicato and arco allocate one extra sound, reused")
    func repeatedTechniqueReusesItsChannel() {
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        var lane: [SystemMeasure] = []
        for bar in 0 ..< 20 {
            var text = StaffText(text: bar.isMultiple(of: 2) ? "pizz." : "arco")
            text.annotation = .playTechnique(bar.isMultiple(of: 2) ? .pizzicato : .natural, playsBack: true)
            lane.append(SystemMeasure(elements: [
                PositionedSystemElement(position: .start, element: .staffText(text), originalStaff: address),
            ]))
        }
        let measures = (0 ..< 20).map { _ in
            Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: ChordNotes([Note(pitch: 69, tpc: 17)]))),
            ])])
        }
        let violin = Instrument(id: "violin", channels: [
            InstrumentChannel(program: 40), InstrumentChannel(name: "pizzicato", program: 45),
        ])
        let score = Score(division: 480, parts: [Part(
            id: "P1", instrument: violin, staves: [Staff(lineCount: 5, measures: measures)],
        )], systemMeasures: IdentifiedArray(lane))
        let points = score.soundTimeline(forPart: 0)
        // The seed, then one point per toggle: 20 — and only the seed and the first pizzicato are new sounds.
        #expect(points.count == 21)
        #expect(points.count { $0.reusesPoint == nil } == 2)
        #expect(Set(points.compactMap(\.reusesPoint)) == [0, 1])
    }
}
