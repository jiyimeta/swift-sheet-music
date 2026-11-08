#if os(Android)
    import CJNI
    import SheetMusicAudioCore
    import SheetMusicAudioSwiftySynthCore

    /// `SwiftySynthNative.nativeRenderMix(score, metronome, metronomeAudible, frames, left, right, metronomeLeft,
    /// metronomeRight)`: renders `frames` frames of the score synth behind `score`, its recordings mixed in, into
    /// `left` / `right`, and of the metronome synth behind `metronome` (0 for none) into `metronomeLeft` /
    /// `metronomeRight` — zeroed unless `metronomeAudible` (`HostedSynth.renderMix`). Answers `frames`, or 0 — arrays
    /// untouched — for an unknown score handle, a non-positive count or an array too short.
    ///
    /// Hand-written for the reason `nativeRender` is: one crossing per output block, nothing allocated. Both synths'
    /// locks are taken — the score's, then the metronome's, the one order any caller takes two in — *before* the four
    /// arrays are pinned, so nothing waits inside a critical region.
    @_cdecl("Java_io_github_jiyimeta_sheetmusic_audio_synth_SwiftySynthNative_nativeRenderMix")
    // swiftlint:disable:next identifier_name function_parameter_count
    public func Java_io_github_jiyimeta_sheetmusic_audio_synth_SwiftySynthNative_nativeRenderMix(
        _ envPointer: UnsafeMutablePointer<JNIEnv?>,
        _: jobject?,
        _ score: jlong,
        _ metronome: jlong,
        _ metronomeAudible: jboolean,
        _ frames: jint,
        _ left: jfloatArray?,
        _ right: jfloatArray?,
        _ metronomeLeft: jfloatArray?,
        _ metronomeRight: jfloatArray?,
    ) -> jint {
        guard frames > 0, let env = envPointer.pointee, let left, let right, let metronomeLeft, let metronomeRight,
              let synth = SynthBridge.synth(Int64(score)),
              env.pointee.GetArrayLength(envPointer, left) >= frames,
              env.pointee.GetArrayLength(envPointer, right) >= frames,
              env.pointee.GetArrayLength(envPointer, metronomeLeft) >= frames,
              env.pointee.GetArrayLength(envPointer, metronomeRight) >= frames
        else { return 0 }
        let click = metronome == 0 ? nil : SynthBridge.synth(Int64(metronome))
        return synth.withMixLocks(metronome: click) { () -> jint in
            // Pinned one inside the other and released in reverse, with no array to hold them: nothing allocates.
            withCritical(env, envPointer, left) { leftStorage -> jint? in
                withCritical(env, envPointer, right) { rightStorage -> jint? in
                    withCritical(env, envPointer, metronomeLeft) { clickLeft -> jint? in
                        withCritical(env, envPointer, metronomeRight) { clickRight -> jint? in
                            synth.renderMixHoldingLocks(
                                left: leftStorage, right: rightStorage, metronome: click,
                                metronomeLeft: clickLeft, metronomeRight: clickRight,
                                metronomeAudible: metronomeAudible != 0, frames: Int(frames),
                            )
                            return frames
                        }
                    }
                }
            } ?? 0
        }
    }

    /// Runs `body` on `array`'s storage, pinned with `GetPrimitiveArrayCritical`, and releases it after (writing it
    /// back); nil, and `body` not run, when the VM could not pin it. Generic and inlined: no closure context allocates.
    @inline(__always)
    private func withCritical<R>(
        _ env: JNIEnv, _ envPointer: UnsafeMutablePointer<JNIEnv?>,
        _ array: jfloatArray, _ body: (UnsafeMutablePointer<Float>) -> R?,
    ) -> R? {
        guard let storage = env.pointee.GetPrimitiveArrayCritical(envPointer, array, nil) else { return nil }
        let result = body(storage.assumingMemoryBound(to: Float.self))
        // A body that could not finish wrote nothing worth keeping.
        env.pointee.ReleasePrimitiveArrayCritical(envPointer, array, storage, result == nil ? JNI_ABORT : 0)
        return result
    }

    /// `RecordingPcmNative.nativeAppend(writer, samples, frameCount, channels)`: appends `frameCount` frames of
    /// `channels` (1 or 2) interleaved Int16 samples from the start of `samples` to the cache file behind `writer`
    /// (`nativeRecordingCacheWriterOpen`). Answers 0, or -1 for an unknown writer, an array too short, or a write that
    /// failed — the writer is then cancelled, and `finish` answers "".
    @_cdecl("Java_io_github_jiyimeta_sheetmusic_audio_recording_RecordingPcmNative_nativeAppend")
    // swiftlint:disable:next identifier_name
    public func Java_io_github_jiyimeta_sheetmusic_audio_recording_RecordingPcmNative_nativeAppend(
        _ envPointer: UnsafeMutablePointer<JNIEnv?>,
        _: jobject?,
        _ writer: jlong,
        _ samples: jshortArray?,
        _ frameCount: jint,
        _ channels: jint,
    ) -> jint {
        guard frameCount >= 0, channels == 1 || channels == 2, let env = envPointer.pointee, let samples,
              env.pointee.GetArrayLength(envPointer, samples) >= frameCount * channels
        else { return -1 }
        guard frameCount > 0 else { return 0 }
        // Not a critical region: the write may block on the disk, which a critical region must never do.
        guard let elements = env.pointee.GetShortArrayElements(envPointer, samples, nil) else { return -1 }
        defer { env.pointee.ReleaseShortArrayElements(envPointer, samples, elements, JNI_ABORT) }
        return recordingCacheWriterAppend(
            handle: Int64(writer), samples: UnsafePointer(elements), frameCount: Int(frameCount),
            channels: Int(channels),
        )
    }
#endif
