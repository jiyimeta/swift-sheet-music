#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    import Testing

    /// The entry points Kotlin's `SwiftySynthDriver` and `PlayerDriver` call, driven as Kotlin drives them.
    struct SynthBridgeTests {
        private func peak(rendering handle: Int64, frames: Int = 2205) -> (frames: Int, peak: Float) {
            let buffer = StereoBuffer(frames: frames)
            let rendered = SynthBridge.render(handle: handle, left: buffer.left, right: buffer.right, frames: frames)
            return (rendered, buffer.peak)
        }

        @Test func `a synth loads a font from a path and plays a note`() throws {
            let url = try HostedSynthFixtures.clickFontFile(seconds: 1)
            defer { try? FileManager.default.removeItem(at: url) }
            let synth = nativeSynthCreate(sampleRate: 48000, voicing: 0)
            #expect(synth != 0)
            defer { nativeSynthRelease(handle: synth) }
            #expect(nativeSynthLoadSoundFont(handle: synth, path: url.path) == 0)
            nativeSynthProgramSelect(handle: synth, channel: 9, bank: 128, program: 0)
            nativeSynthNoteOn(handle: synth, channel: 9, key: Int32(HostedSynthFixtures.strongKey), velocity: 100)
            let rendered = peak(rendering: synth)
            #expect(rendered.frames == 2205)
            #expect(rendered.peak > 0.01)
        }

        @Test func `a missing font answers -1 and the synth stays silent`() {
            let synth = nativeSynthCreate(sampleRate: 48000, voicing: 1)
            defer { nativeSynthRelease(handle: synth) }
            #expect(nativeSynthLoadSoundFont(handle: synth, path: "/nonexistent/font.sf2") == -1)
            nativeSynthNoteOn(handle: synth, channel: 9, key: 76, velocity: 100)
            #expect(peak(rendering: synth).peak == 0)
        }

        @Test func `a refused sample rate and unknown handles answer the failure values`() {
            #expect(nativeSynthCreate(sampleRate: 1000, voicing: 0) == 0)
            #expect(nativeSynthLoadSoundFont(handle: 0, path: "/x.sf2") == -1)
            #expect(nativeSynthControllerValue(handle: 0, channel: 0, controller: 7) == -1)
            #expect(nativeSequenceCreate(synthHandle: 0, smf: Data()) == 0)
            #expect(nativeSequenceCurrentTick(handle: 0) == 0)
            #expect(peak(rendering: 0).frames == 0)
        }

        @Test func `controller values read back what the host set`() {
            let synth = nativeSynthCreate(sampleRate: 48000, voicing: 0)
            defer { nativeSynthRelease(handle: synth) }
            #expect(nativeSynthControllerValue(handle: synth, channel: 3, controller: 7) == 100)
            nativeSynthControlChange(handle: synth, channel: 3, controller: 7, value: 42)
            #expect(nativeSynthControllerValue(handle: synth, channel: 3, controller: 7) == 42)
        }

        @Test func `a sequence seeks, plays and reports ticks, and outlives its synth's release`() throws {
            let synth = nativeSynthCreate(sampleRate: 48000, voicing: 0)
            let smf = try HostedSynthFixtures.smf(
                notes: (0 ..< 8).map { (tick: $0 * 480, channel: 9, key: 76, length: 240) },
            )
            let sequence = nativeSequenceCreate(synthHandle: synth, smf: smf)
            #expect(sequence != 0)
            nativeSequenceSeek(handle: sequence, tick: 480)
            #expect(nativeSequenceCurrentTick(handle: sequence) == 480)
            nativeSequenceSetSpeed(handle: sequence, speed: 2)
            nativeSequencePlay(handle: sequence)
            _ = peak(rendering: synth, frames: 12000) // 0.25 s at twice the speed
            #expect(abs(nativeSequenceCurrentTick(handle: sequence) - 960) <= 2)
            nativeSequenceStop(handle: sequence)
            nativeSynthRelease(handle: synth)
            // The synth is closed; the sequence still holds it, inert.
            #expect(nativeSequenceCurrentTick(handle: sequence) == 0)
            nativeSequenceRelease(handle: sequence)
        }
    }
#endif
