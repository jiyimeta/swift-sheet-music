#if canImport(SheetMusicAudioSwiftySynthCore)
    import Foundation
    import SheetMusicAudioCore
    import SheetMusicAudioSwiftySynthCore
    import SheetMusicMIDI
    import SwiftySynth
    import Testing

    /// The synth settings every SwiftySynth host builds with, and the dispatch that turns the choke marker into a
    /// choke.
    struct SwiftySynthVoicingTests {
        @Test func `the score voicing is the Apple backend's full synth`() throws {
            let synth = try #require(SwiftySynthVoicing.score.makeSynthesizer(
                soundFont: HostedSynthFixtures.clickFont(), sampleRate: 48000,
            ))
            #expect(synth.maximumPolyphony == 256)
            #expect(synth.enableReverbAndChorus)
            #expect(synth.enableModulators)
            #expect(synth.masterVolume == 1)
            #expect(synth.sampleRate == 48000)
        }

        @Test func `the metronome voicing is eight dry voices`() throws {
            let synth = try #require(SwiftySynthVoicing.metronome.makeSynthesizer(
                soundFont: HostedSynthFixtures.clickFont(), sampleRate: 44100,
            ))
            #expect(synth.maximumPolyphony == 8)
            #expect(!synth.enableReverbAndChorus)
            #expect(synth.enableModulators)
            #expect(synth.masterVolume == 1)
        }

        @Test func `a sample rate SwiftySynth refuses builds no synth`() throws {
            let font = try HostedSynthFixtures.clickFont()
            #expect(SwiftySynthVoicing.score.makeSynthesizer(soundFont: font, sampleRate: 1000) == nil)
        }

        /// A 2 s click on the percussion channel rings on after a quarter second unless the choke marker reached it.
        @Test(arguments: [false, true])
        func `the choke marker chokes and every other message passes`(choked: Bool) throws {
            let synth = try #require(SwiftySynthVoicing.metronome.makeSynthesizer(
                soundFont: HostedSynthFixtures.clickFont(seconds: 2), sampleRate: 44100,
            ))
            let send = SwiftySynthVoicing.sendTurningChokesIntoChokes
            send(synth, 9, 0x90, HostedSynthFixtures.strongKey, 100)
            HostedSynthFixtures.render(synth, seconds: 0.05)
            // An ordinary controller passes through untouched; the marker chokes.
            send(synth, 9, 0xB0, 7, 127)
            if choked {
                send(synth, 9, 0xB0, ChokeMarker.controller, HostedSynthFixtures.strongKey)
            }
            let peak = HostedSynthFixtures.peak(of: synth, seconds: 0.2, lastSeconds: 0.01)
            if choked {
                #expect(peak < 0.0001, "peak \(peak) after the choke")
            } else {
                #expect(peak > 0.01, "peak \(peak) with no choke")
            }
        }

        @Test func `the sequencer it builds dispatches through the choke hook`() throws {
            let synth = try #require(SwiftySynthVoicing.score.makeSynthesizer(
                soundFont: HostedSynthFixtures.clickFont(), sampleRate: 44100,
            ))
            let sequencer = SwiftySynthVoicing.makeSequencer(driving: synth)
            #expect(sequencer.synthesizer === synth)
            #expect(sequencer.onSend != nil)
        }
    }
#endif
