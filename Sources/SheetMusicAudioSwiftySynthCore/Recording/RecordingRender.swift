import SheetMusicAudioCore

/// The recordings' half of a SwiftySynth render: what the Apple backend and Android's `HostedSynth` both mix onto the
/// score's output, on the render thread. Allocation-free.
package enum RecordingRender {
    /// The crossfade on a jump of a recording's read position, and its fade-in after silence (P1's value).
    package static let fadeSeconds = 0.005

    /// Add every recording to one chunk of the body, whose first frame is at transport second `transportStart` and
    /// whose frames each advance the transport by `transportPerFrame`. The speed table turns each frame's transport
    /// second into a warped one, where the group's schedule — its own, or the shared one — says what each track plays.
    /// A group at 100 % and no transposition is read directly, track by track; any other is read through its
    /// stretcher. A switch between the two is a jump: the reading switched from fades out while the other fades in.
    ///
    /// A track handed a new gain heads for it over the fade (`RecordingGainRamp`): per output frame when read
    /// directly, per input frame when read through a stretcher, whose input carries the gain. A track nothing is heard
    /// from takes its new gain at once instead, so it comes back at that gain: read directly, a ramp from the old one
    /// would run against the fade-in; read through a stretcher, the prime's history would carry the old one for a
    /// stretcher lead. Allocation-free.
    package static func mixRecordings(
        into left: UnsafeMutableBufferPointer<Float>,
        _ right: UnsafeMutableBufferPointer<Float>,
        transportStart: Double,
        transportPerFrame: Double,
        sampleRate: Double,
        alignment: inout PlaybackAlignmentState,
    ) {
        // Every track is in a group, and a group left draining has no track in the list: groups decide.
        guard !left.isEmpty, !alignment.groups.isEmpty else { return }
        let clock = ChunkClock(
            transportStart: transportStart, transportPerFrame: transportPerFrame,
            frames: left.count, table: alignment.speedTable,
        )
        let fadeFrames = max(1, Int((fadeSeconds * sampleRate).rounded()))
        for index in alignment.tracks.indices {
            let gain = alignment.tracks[index].gain
            alignment.tracks[index].gainRamp.head(for: gain, frames: fadeFrames)
        }
        for group in alignment.groups.indices {
            let stretched = alignment.readsThroughStretcher(group: group)
            // A track with a table of its own is in a group of that table, and was handed over at offset 0.
            let schedule = if let own = alignment.groups[group].schedule { own } else { alignment.schedule }
            // A draining group's track indices are into its own tracks: only its stretcher finishes fading out.
            let liveTracks = alignment.groups[group].drainTracks == nil
            // A track heard from nowhere steps to its gain: its direct reading is silent, and so is the stretcher when
            // it is the one read. A reading that starts in this chunk then fades in at that gain, and a stretcher is
            // primed with it. (A stretcher fading out under a switch to direct reading is not heard from the input
            // this chunk feeds it: that reaches its output a lead later, after the fade.)
            if liveTracks, !stretched || alignment.groups[group].state.isSilent {
                for index in alignment.groups[group].trackIndices where alignment.tracks[index].playhead.isSilent {
                    let gain = alignment.tracks[index].gain
                    alignment.tracks[index].gainRamp.settle(at: gain)
                }
            }
            for index in alignment.groups[group].trackIndices where liveTracks {
                if stretched {
                    fadeOutTrack(
                        &alignment.tracks[index], into: left, right, clock: clock,
                        table: alignment.speedTable, fadeFrames: fadeFrames,
                    )
                } else {
                    mixTrack(
                        &alignment.tracks[index], into: left, right, clock: clock,
                        table: alignment.speedTable, schedule: schedule, fadeFrames: fadeFrames,
                    )
                }
            }
            let fed = mixStretchGroup(
                group, playing: stretched, into: left, right, clock: clock,
                sampleRate: sampleRate, fadeFrames: fadeFrames, alignment: &alignment,
            )
            // The stretched reading read each track's ramp without moving it (its reader held the track list, which
            // must not be written meanwhile); the frames it fed move it now.
            if stretched, fed > 0 {
                for index in alignment.groups[group].trackIndices {
                    alignment.tracks[index].gainRamp.advance(by: fed)
                }
            }
        }
    }

    /// A track whose group is read through its stretcher: its direct reading fades out from where it was, then is
    /// skipped. Its gain ramp is read, not moved: the stretched reading moves it.
    package static func fadeOutTrack(
        _ track: inout RenderedRecording,
        into left: UnsafeMutableBufferPointer<Float>,
        _ right: UnsafeMutableBufferPointer<Float>,
        clock: ChunkClock,
        table: TransportSpeedTable,
        fadeFrames: Int,
    ) {
        guard !track.playhead.isSilent else { return }
        let frames = track.frames
        let rate = frames.sampleRate
        var gain = track.gainRamp
        var playhead = track.playhead
        var output = clock.outputSeconds(atFrame: 0, table: table)
        for frame in 0 ..< left.count where !playhead.isSilent {
            let next = clock.outputSeconds(atFrame: frame + 1, table: table)
            let step = (next - output) * rate
            let sample = playhead.render(target: nil, step: step, from: frames, fadeFrames: fadeFrames)
            let scale = gain.next()
            left[frame] += scale * sample.left
            right[frame] += scale * sample.right
            output = next
        }
        track.playhead = playhead
    }

    /// One track over one chunk: per frame, the warped second → the track file's second (nil = silence) → its frame,
    /// read by the playhead, which crossfades a jump and fades in after silence, and scaled by the track's gain as its
    /// ramp stands at that frame.
    package static func mixTrack(
        _ track: inout RenderedRecording,
        into left: UnsafeMutableBufferPointer<Float>,
        _ right: UnsafeMutableBufferPointer<Float>,
        clock: ChunkClock,
        table: TransportSpeedTable,
        schedule: RecordingSchedule,
        fadeFrames: Int,
    ) {
        let frames = track.frames
        let rate = frames.sampleRate
        let offset = track.offsetSeconds
        var gain = track.gainRamp
        var playhead = track.playhead
        var output = clock.outputSeconds(atFrame: 0, table: table)
        for frame in 0 ..< left.count {
            let next = clock.outputSeconds(atFrame: frame + 1, table: table)
            let source = schedule.sourceSeconds(atOutput: output, offset: offset)
            let target: Double? = if let source { source * rate } else { nil }
            let sample = playhead.render(
                target: target, step: (next - output) * rate, from: frames, fadeFrames: fadeFrames,
            )
            let scale = gain.next()
            left[frame] += scale * sample.left
            right[frame] += scale * sample.right
            output = next
        }
        track.playhead = playhead
        track.gainRamp = gain
    }
}
