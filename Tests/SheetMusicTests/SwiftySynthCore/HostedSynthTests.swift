#if canImport(SheetMusicAudioSwiftySynthCore)
    import Foundation
    import SheetMusicAudioSwiftySynthCore
    @testable import SheetMusicCore
    import SheetMusicMIDI
    import SwiftySynth
    import Testing

    /// The synth Android's engine drives: messages, a transport in ticks, and what survives the sequencer's resets.
    struct HostedSynthTests {
        private static let rate = 44100

        /// Renders `seconds` in 480-frame blocks, as Android's output writer pulls, answering the peak of the last
        /// `lastSeconds` (all of it by default).
        @discardableResult
        private func render(_ synth: HostedSynth, seconds: Double, lastSeconds: Double? = nil) -> Float {
            let total = Int(seconds * Double(Self.rate))
            let tailStart = total - Int((lastSeconds ?? seconds) * Double(Self.rate))
            let buffer = StereoBuffer(frames: 480)
            var peak: Float = 0
            var done = 0
            while done < total {
                let frames = min(480, total - done)
                synth.render(left: buffer.left, right: buffer.right, frames: frames)
                for i in 0 ..< frames where done + i >= tailStart {
                    peak = max(peak, abs(buffer.left[i]), abs(buffer.right[i]))
                }
                done += frames
            }
            return peak
        }

        private func clickSynth(seconds: Double = 2, voicing: SwiftySynthVoicing = .score) throws -> HostedSynth {
            let synth = try #require(HostedSynth(sampleRate: Self.rate, voicing: voicing))
            #expect(try synth.loadSoundFont(HostedSynthFixtures.clickFont(seconds: seconds)))
            synth.programSelect(channel: 9, bank: 128, program: 0)
            return synth
        }

        /// Clicks on the percussion channel every quarter for `quarters` quarters at 120 bpm (480 PPQ) unless tempos
        /// say otherwise.
        private func clickTrack(quarters: Int = 8, tempos: [(tick: Int, bpm: Double)] = []) throws -> Data {
            try HostedSynthFixtures.smf(
                tempos: tempos,
                notes: (0 ..< quarters).map {
                    (tick: $0 * 480, channel: 9, key: HostedSynthFixtures.strongKey, length: 240)
                },
            )
        }

        @Test func `before a font loads the synth is silent`() throws {
            let synth = try #require(HostedSynth(sampleRate: Self.rate, voicing: .score))
            synth.noteOn(channel: 9, key: HostedSynthFixtures.strongKey, velocity: 100)
            #expect(render(synth, seconds: 0.05) == 0)
        }

        @Test func `a note sounds once a font is loaded, and stops with the synth`() throws {
            let synth = try clickSynth()
            synth.noteOn(channel: 9, key: HostedSynthFixtures.strongKey, velocity: 100)
            #expect(render(synth, seconds: 0.05) > 0.01)
            synth.close()
            #expect(render(synth, seconds: 0.05) == 0)
        }

        @Test func `a seek reports its tick at once and the transport runs from there`() throws {
            let synth = try clickSynth()
            let sequence = try #require(synth.attachSequence(smf: clickTrack()))
            sequence.seek(toTick: 480)
            #expect(sequence.currentTick == 480)
            sequence.play()
            render(synth, seconds: 0.5)
            #expect(abs(sequence.currentTick - 960) <= 2, "\(sequence.currentTick)")
        }

        @Test func `the transport follows the SMF's tempo changes`() throws {
            let synth = try clickSynth()
            let sequence = try #require(synth.attachSequence(smf: clickTrack(tempos: [(0, 120), (960, 60)])))
            sequence.play()
            render(synth, seconds: 2.0)
            #expect(abs(sequence.currentTick - 1440) <= 2, "\(sequence.currentTick)")
        }

        @Test func `speed scales how fast the ticks go by`() throws {
            let synth = try clickSynth()
            let sequence = try #require(synth.attachSequence(smf: clickTrack()))
            sequence.setSpeed(2)
            sequence.play()
            render(synth, seconds: 0.5)
            #expect(abs(sequence.currentTick - 960) <= 2, "\(sequence.currentTick)")
        }

        /// On the dry metronome voicing, so no reverb tail keeps the output from reading zero.
        @Test func `a stopped transport holds its tick and its voices end`() throws {
            let synth = try clickSynth(voicing: .metronome)
            let sequence = try #require(synth.attachSequence(smf: clickTrack()))
            sequence.play()
            #expect(render(synth, seconds: 0.1) > 0.01)
            sequence.stop()
            let held = sequence.currentTick
            // After the block the synthesizer had already rendered when the voices were cut (64 frames at most).
            #expect(render(synth, seconds: 0.1, lastSeconds: 0.09) == 0)
            #expect(sequence.currentTick == held)
        }

        /// The engine mutes a strip with CC 7 = 0 before playing; the sequencer's reset on seek must not undo it.
        @Test(arguments: [false, true])
        func `the host's channel state survives a seek`(muted: Bool) throws {
            let synth = try clickSynth()
            if muted { synth.controlChange(channel: 9, controller: 7, value: 0) }
            let sequence = try #require(synth.attachSequence(smf: clickTrack()))
            sequence.seek(toTick: 0)
            sequence.play()
            let peak = render(synth, seconds: 0.1)
            if muted {
                #expect(peak == 0)
            } else {
                #expect(peak > 0.01)
            }
            #expect(synth.controllerValue(channel: 9, controller: 7) == (muted ? 0 : 100))
        }

        @Test func `a replaced sequence goes inert`() throws {
            let synth = try clickSynth()
            let first = try #require(synth.attachSequence(smf: clickTrack()))
            let second = try #require(synth.attachSequence(smf: clickTrack()))
            first.seek(toTick: 960)
            #expect(first.currentTick == 0)
            #expect(second.currentTick == 0)
            second.seek(toTick: 480)
            #expect(second.currentTick == 480)
            second.detach()
            #expect(second.currentTick == 0)
        }

        @Test func `bytes that are not an SMF attach nothing`() throws {
            let synth = try clickSynth()
            #expect(synth.attachSequence(smf: Data([0, 1, 2])) == nil)
        }

        /// No gain of its own: what the score voicing's synthesizer and sequencer render for the same SMF, sample for
        /// sample, whatever block size the host pulls in. That is the Apple backend's level too, so a score sounds as
        /// loud on Android as on a Mac.
        @Test func `it renders what the score voicing renders`() throws {
            let font = try HostedSynthFixtures.clickFont(seconds: 0.3)
            let smf = try clickTrack(quarters: 4)
            let frames = Self.rate

            let reference = try #require(
                SwiftySynthVoicing.score.makeSynthesizer(soundFont: font, sampleRate: Self.rate),
            )
            let sequencer = SwiftySynthVoicing.makeSequencer(driving: reference)
            try sequencer.play(SwiftySynth.MidiFile(data: smf), loop: false)
            var expectedLeft = [Float](repeating: 0, count: frames)
            var expectedRight = expectedLeft
            expectedLeft.withUnsafeMutableBufferPointer { l in
                expectedRight.withUnsafeMutableBufferPointer { r in sequencer.render(left: l, right: r) }
            }

            let hosted = try #require(HostedSynth(sampleRate: Self.rate, voicing: .score))
            #expect(hosted.loadSoundFont(font))
            let sequence = try #require(hosted.attachSequence(smf: smf))
            sequence.play()
            let buffer = StereoBuffer(frames: frames)
            var done = 0
            while done < frames {
                let block = min(480, frames - done)
                hosted.render(left: buffer.left + done, right: buffer.right + done, frames: block)
                done += block
            }
            #expect(expectedLeft.contains { $0 != 0 })
            #expect(buffer.leftSamples == expectedLeft)
            #expect(buffer.rightSamples == expectedRight)
        }
    }

    /// Against a real General MIDI font: the drum bank and the choke.
    struct HostedSynthGeneralMIDITests {
        private static let rate = 44100

        private func renderPCM(_ body: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int) -> Void)
            -> [Float]
        {
            let buffer = StereoBuffer(frames: Self.rate / 5)
            body(buffer.left, buffer.right, buffer.frames)
            return buffer.leftSamples + buffer.rightSamples
        }

        /// What a bare synthesizer of the score voicing plays for `key` on the percussion channel after `messages`.
        private func reference(_ font: SoundFont, key: Int, messages: [(Int, Int, Int, Int)]) throws -> [Float] {
            let synth = try #require(SwiftySynthVoicing.score.makeSynthesizer(soundFont: font, sampleRate: Self.rate))
            for (channel, command, data1, data2) in messages {
                synth.processMidiMessage(channel: channel, command: command, data1: data1, data2: data2)
            }
            synth.noteOn(key: key, velocity: 100, on: 9)
            return renderPCM { l, r, n in
                synth.render(left: UnsafeMutableBufferPointer(start: l, count: n), right: .init(start: r, count: n))
            }
        }

        private func hosted(_ font: SoundFont, key: Int, bank: Int, program: Int) throws -> [Float] {
            let synth = try #require(HostedSynth(sampleRate: Self.rate, voicing: .score))
            #expect(synth.loadSoundFont(font))
            synth.programSelect(channel: 9, bank: bank, program: program)
            synth.noteOn(channel: 9, key: key, velocity: 100)
            return renderPCM { l, r, n in synth.render(left: l, right: r, frames: n) }
        }

        /// Bank 128 is the drum bank; on the percussion channel SwiftySynth selects it from bank select 0, so a kit
        /// number picks that kit — the engine's `programSelect(bank: 128, program: kit)` for a drum strip.
        @Test(.enabled(if: HostedSynthFixtures.generalUserPath != nil))
        func `bank 128 on the percussion channel selects the drum kit`() throws {
            let font = try SoundFont(url: URL(fileURLWithPath: #require(HostedSynthFixtures.generalUserPath)))
            let standard = try hosted(font, key: 38, bank: 128, program: 0)
            #expect(try standard == reference(font, key: 38, messages: []))
            let kit = try hosted(font, key: 38, bank: 128, program: 25)
            #expect(try kit == reference(font, key: 38, messages: [(9, 0xB0, 0, 0), (9, 0xC0, 25, 0)]))
            #expect(kit != standard, "kit 25 is not the standard kit in GeneralUser GS")
        }

        /// A quarter crash at 120 bpm, choked or not, rendered through the hosted sequence: the marker the playback
        /// render writes reaches `Synthesizer.choke` on Android exactly as on Apple.
        @Test(.enabled(if: HostedSynthFixtures.generalUserPath != nil), arguments: [false, true])
        func `a choked crash is silent shortly after its written end`(choked: Bool) throws {
            let font = try SoundFont(url: URL(fileURLWithPath: #require(HostedSynthFixtures.generalUserPath)))
            let synth = try #require(HostedSynth(sampleRate: Self.rate, voicing: .score))
            #expect(synth.loadSoundFont(font))
            synth.programSelect(channel: 9, bank: 128, program: 0)
            // What the playback render writes for a crash quarter, choked or not — the same score the Apple backend's
            // choke suite plays.
            var score = RevoiceFixtures.score([["C/4 r/4 r/2"]])
            if choked {
                score = RevoiceFixtures.editingChord(score, measure: 0, voice: 0, element: 1) {
                    $0.articulations = [ChordArticulation(kind: .chokeCymbal)]
                }
            }
            let smf = try MidiWriter.write(MidiRenderer.renderForPlayback(score: score))
            let sequence = try #require(synth.attachSequence(smf: smf))
            sequence.play()
            let buffer = StereoBuffer(frames: 441)
            for _ in 0 ..< 60 { // 0.6 s in 10 ms slices; the crash is written to end at 0.5 s
                synth.render(left: buffer.left, right: buffer.right, frames: buffer.frames)
            }
            let peak = buffer.peak
            if choked {
                #expect(peak < 0.003_162, "peak \(peak) at 0.6 s")
            } else {
                #expect(peak > 0.01, "peak \(peak) at 0.6 s")
            }
        }
    }
#endif
