import Foundation
@testable import SheetMusicAudioCore
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

/// What the part's annotations do to the SMF, the live plan and the audition table.
@Suite("Technique channels")
struct TechniqueChannelTests {
    private static let bar = 1920

    /// The channel each bar's notes sound on, for track `track`.
    private static func channels(_ midi: MidiFile, track: Int) -> [Int] {
        let notes = midi.tracks[track].events.compactMap { timed -> (Int, Int)? in
            if case let .noteOn(channel, _, _) = timed.event { (timed.tick / bar, channel) } else { nil }
        }
        return (0 ..< 6).map { bar in notes.first { $0.0 == bar }?.1 ?? -1 }
    }

    private static func program(of channel: Int, in midi: MidiFile, track: Int) -> Int? {
        midi.tracks[track].events.compactMap { timed -> Int? in
            if case let .programChange(shown, program) = timed.event, shown == channel { program } else { nil }
        }.first
    }

    @Test("the violin sounds pizzicato from its bar to the arco, then tremolo; a muted-flag annotation is nothing")
    func pizzicatoSwitchesChannelAndBack() throws {
        let midi = try MidiRenderer.render(score: AnnotationFixtures.load("w5-play-techniques"))
        let channels = Self.channels(midi, track: 0)
        #expect(channels[0] == channels[2])
        #expect(channels[0] == channels[5])
        #expect(channels[1] != channels[0])
        #expect(channels[3] == channels[4])
        #expect(channels[3] != channels[0])
        #expect(channels[3] != channels[1])
        #expect(Self.program(of: channels[0], in: midi, track: 0) == 40)
        #expect(Self.program(of: channels[1], in: midi, track: 0) == 45)
        #expect(Self.program(of: channels[3], in: midi, track: 0) == 44)
    }

    /// MuseScore allocates a channel per `<Channel>` and sends a technique's notes to its own; a variant taking a
    /// fresh one would push a string quartet (three channels each) past the 15 melodic channels.
    @Test("the violin's techniques sound on the channels its <Channel>s already own")
    func namedChannelsAllocateNothing() throws {
        let score = try AnnotationFixtures.load("w5-play-techniques")
        let assignments = MidiRenderer.assignChannels(score: score)
        #expect(assignments[0].count == 3)
        #expect(Set(assignments[0].map(\.instrumentOrdinal)) == [0])
        // The guitar has one channel: its General MIDI sounds (mute 28, harmonics 31) take one each.
        #expect(assignments[1].count == 3)
    }

    @Test("the guitar mutes, plays harmonics and returns, through General MIDI programs")
    func muteWithNoChannelUsesGeneralMidi() throws {
        let midi = try MidiRenderer.render(score: AnnotationFixtures.load("w5-play-techniques"))
        let channels = Self.channels(midi, track: 1)
        let programs = channels.map { Self.program(of: $0, in: midi, track: 1) }
        #expect(programs == [25, 28, 25, 31, 31, 25])
        #expect(channels[0] == channels[2])
        #expect(channels[0] == channels[5])
    }

    @Test("the live plan has a strip and a channel per sound, labeled with the technique")
    func liveStripsPerSound() throws {
        let score = try AnnotationFixtures.load("w5-play-techniques")
        let plan = LiveChannelPlan.build(score: score)
        let violin = plan.strips.filter { $0.partIndex == 0 }
        #expect(violin.count == 3)
        #expect(Set(violin.map(\.liveChannel)).count == 3)
        let labels = violin.map { plan.labels(for: $0, in: score).displayName }
        #expect(labels.contains("Violin (Pizzicato)"))
        #expect(labels.contains("Violin (Tremolo)"))
        // The rendered pizzicato channel plays on the pizzicato strip, not the violin's.
        let rendered = MidiRenderer.assignChannels(score: score)[0]
        let pizzicato = try #require(violin.first { $0.instrument.trackName == "Pizzicato" })
        #expect(plan.remap[rendered[1].key] == pizzicato.liveChannel)
        #expect(plan.remap[rendered[0].key] == violin.first?.liveChannel)
    }

    @Test("the audition table switches channel at each technique that changes the sound")
    func auditionSwitches() throws {
        let score = try AnnotationFixtures.load("w5-play-techniques")
        let plan = LiveChannelPlan.build(score: score)
        let switches = try #require(PreparedPlayback.staffChannelSwitches(score: score, plan: plan)[0])
        #expect(switches.map(\.tick) == [0, Self.bar, 2 * Self.bar, 3 * Self.bar, 5 * Self.bar])
        let live = switches.map(\.channel)
        try #require(live.count == 5)
        #expect(live[0] == live[2])
        #expect(live[0] == live[4])
        #expect(Set(live).count == 3)
    }

    @Test("a score with no technique allocates the channels its instrument timeline always did")
    func scoreWithoutTechniquesIsUnchanged() throws {
        for name in ["instrument-change", "w5-capo-playback"] {
            let score = try AnnotationFixtures.load(name)
            let sounds = score.parts.indices.map { score.soundTimeline(forPart: $0).map(\.instrument) }
            let instruments = score.parts.indices.map { score.instrumentTimeline(forPart: $0).map(\.instrument) }
            #expect(sounds == instruments, "\(name)")
            let allocated = MidiRenderer.assignChannels(score: score).map { Set($0.map(\.instrumentOrdinal)).count }
            #expect(allocated == instruments.map(\.count), "\(name)")
        }
    }
}
