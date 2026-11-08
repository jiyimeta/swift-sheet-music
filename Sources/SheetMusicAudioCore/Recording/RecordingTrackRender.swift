import SheetMusicFoundation

/// One recording as a backend mixes it: the mapped PCM and how it sits against the reference timing, with the gain and
/// transposition the engine has already resolved from the mixer.
public struct RecordingTrackRender: Sendable {
    /// Stable across calls, so a backend can keep a playing track's position when the set is replaced.
    public let id: String
    public let recording: MappedRecording
    /// Seconds into the reference recording's time at which this track's file starts.
    public var offsetSeconds: TimeInterval
    /// The strip's effective volume × mute × solo, resolved by the engine. A backend ramps to a new gain for a playing
    /// track rather than stepping, which would click: the SwiftySynth backends ramp over their 5 ms recording fade. A
    /// track read through a stretcher (a rate other than 100 %, or a transposition) carries its gain in the stretcher's
    /// input, so there the change reaches the output one stretcher lead late — about 0.1 s with Signalsmith Stretch.
    public var gain: Float
    /// The track's own transposition plus the reader's, resolved by the engine.
    public var transposeSemitones: Double

    public init(
        id: String, recording: MappedRecording, offsetSeconds: TimeInterval = 0, gain: Float = 1,
        transposeSemitones: Double = 0,
    ) {
        self.id = id
        self.recording = recording
        self.offsetSeconds = offsetSeconds
        self.gain = gain
        self.transposeSemitones = transposeSemitones
    }
}

extension RecordingTrackRender {
    /// A recording strip as the backend mixes it — the one rule every engine resolves a strip by. Its gain is its
    /// volume clamped to `0...1`, or 0 when it is muted or the solo bus is engaged (`soloing`: any instrument strip or
    /// recording soloed) without it; its transposition is the reader's plus its own. A recording strip sits on the same
    /// solo bus as the instrument strips; the metronome stays off it.
    package static func resolved(
        id: String, recording: MappedRecording, offsetSeconds: TimeInterval, transposeSemitones: Int,
        readerTransposeSemitones: Int, volume: Float, isMuted: Bool, isSoloed: Bool, soloing: Bool,
    ) -> RecordingTrackRender {
        let silenced = isMuted || (soloing && !isSoloed)
        return RecordingTrackRender(
            id: id, recording: recording, offsetSeconds: offsetSeconds,
            gain: silenced ? 0 : max(0, min(1, volume)),
            transposeSemitones: Double(readerTransposeSemitones + transposeSemitones),
        )
    }
}

/// Reading a recording's pages in ahead of the render thread: which seconds of which table each track plays next.
package enum RecordingPrefetch {
    /// Wall-clock seconds of each recording read in ahead of the transport.
    package static let aheadSeconds = 2.0
    /// File seconds read in behind each stretch as well: a stretcher primed at a jump is fed the input before it.
    package static let behindSeconds = 0.5

    /// The table a track's file seconds come from, and the offset they are read at: its own table at offset 0 when it
    /// has one, since that table is in the file's seconds already; the shared table at the track's `offsetSeconds`
    /// otherwise.
    package static func schedule(
        forTrack id: String, offsetSeconds: TimeInterval, shared: RecordingSchedule, own: [String: RecordingSchedule],
    ) -> (schedule: RecordingSchedule, offset: TimeInterval) {
        if let schedule = own[id] {
            (schedule: schedule, offset: 0)
        } else {
            (schedule: shared, offset: offsetSeconds)
        }
    }

    /// The file seconds a track plays from transport second `transportSeconds` on, `aheadSeconds` of wall-clock time
    /// at `rate` (and never fewer warped seconds than that), each stretch widened back by `behindSeconds` for the
    /// history a stretcher is primed with. `table` turns the transport second into a warped one and `schedule` the
    /// warped window into the track's file, at its `offset`.
    package static func ranges(
        transportSeconds: TimeInterval, rate: Double, table: TransportSpeedTable, schedule: RecordingSchedule,
        offset: TimeInterval,
    ) -> [Range<TimeInterval>] {
        let output = table.outputSeconds(atTransport: transportSeconds)
        let speed = rate.isFinite ? max(1, rate) : 1
        let window = schedule.sourceRanges(fromOutput: output, to: output + aheadSeconds * speed, offset: offset)
        return window.map { max(0, $0.lowerBound - behindSeconds) ..< $0.upperBound }
    }
}
