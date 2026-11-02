import SheetMusicAudioApple
import SheetMusicAudioCore

// The recordings that share one transposition and one table, read through one stretcher pair when the rate is not
// 100 % or the transposition is not 0 (`SwiftySynthBackend+Stretch.swift`). The pair and the scratch are made on the
// main actor and handed to the render thread in a lock swap; the render thread only calls them.

/// A group's two stretchers. The active one plays the current stream; at a jump the other is primed at the new
/// position and faded to, so a jump never waits on the stretcher's latency.
struct StretcherPair {
    let first: any RecordingStretcher
    let second: any RecordingStretcher

    init(factory: RecordingStretcherFactory, sampleRate: Double) {
        first = factory.make(sampleRate)
        second = factory.make(sampleRate)
    }

    subscript(voice: Int) -> any RecordingStretcher {
        voice == 0 ? first : second
    }
}

/// Where a group's stretched reading is, advanced by the render thread. Mirrors `RecordingPlayhead` with two
/// stretchers in place of two read positions.
struct StretchGroupState {
    /// The stretcher playing the current stream, 0 or 1.
    var active = 0
    /// Whether the active stretcher plays a stream; `false` while silent or fading out to silence.
    var hasSource = false
    /// The reference frame (at the engine rate) the next output frame continues from, while `hasSource`.
    var expected: Double = 0
    /// Each stretcher's input cursor: the reference frame of the next input frame it is fed.
    var cursors: (Double, Double) = (0, 0)
    /// Frames left of the current fade, 0 when none.
    var fadeFramesRemaining = 0
    /// The stretcher fading out under the fade, or -1 for a fade in from silence.
    var fadingVoice = -1
    /// Input the fading stretcher is owed but was not fed, under a frame.
    var fadingRemainder: Double = 0
    /// The group's transposition, table or tracks changed, or a track's file or offset: the next frame that plays is a
    /// jump to a stretcher primed with the new input and retuned, so the change is heard after the 5 ms fade rather
    /// than after the stretcher's lead.
    var needsRestart = false

    /// Nothing sounds and nothing fades. A group that is not playing stays so.
    var isSilent: Bool {
        !hasSource && fadeFramesRemaining == 0
    }

    func cursor(_ voice: Int) -> Double {
        voice == 0 ? cursors.0 : cursors.1
    }

    mutating func setCursor(_ voice: Int, _ value: Double) {
        if voice == 0 { cursors.0 = value } else { cursors.1 = value }
    }

    /// The stretched reading stopped (a pause, a stop, a load, a count-in): the next frame that plays fades in.
    mutating func silence() {
        hasSource = false
        fadeFramesRemaining = 0
        fadingVoice = -1
        needsRestart = false
    }
}

/// One group as the render thread reads it.
struct RecordingStretchGroup {
    let transposeSemitones: Double
    /// The table its tracks have of their own (`SynthBackend.setPlaybackAlignment(warp:segments:trackSegments:)`),
    /// laid out on the main actor. Its source seconds are the tracks' file seconds, so each was handed over with its
    /// offset at 0. Nil for tracks without one, which play the shared table (`PlaybackAlignmentState.schedule`) at
    /// their offsets.
    let schedule: RecordingSchedule?
    /// Indices into the tracks it reads: `PlaybackAlignmentState.tracks`, or `drainTracks` while draining.
    let trackIndices: [Int]
    /// Nil until a stretcher is needed and the backend has a factory; the group is then read directly.
    var pair: StretcherPair?
    var state = StretchGroupState()
    /// Set for a group no longer in the track list that was left to fade out: the tracks its stretcher is still fed
    /// until the fade ends. Nil for a group in the track list.
    var drainTracks: [RenderedRecording]?
}

extension RecordingStretchGroup {
    /// The group `layout` describes, reading the tracks at `trackIndices`, its table laid out for the render.
    init(layout: RecordingGroupLayout, trackIndices: [Int], drainTracks: [RenderedRecording]? = nil) {
        self.init(
            transposeSemitones: layout.transposeSemitones,
            schedule: layout.segments.map { RecordingSchedule(segments: $0) },
            trackIndices: trackIndices, pair: layout.pair, drainTracks: drainTracks,
        )
    }
}

/// The main actor's copy of a group: what it holds and its pair, so a new track list or rate can be planned and its
/// stretchers made before the lock, without reading the render thread's state.
struct RecordingGroupLayout {
    let transposeSemitones: Double
    /// The table its tracks have of their own, or nil for the shared one (`RecordingStretchGroup.schedule`).
    let segments: [RecordingSegment]?
    let tracks: [RecordingTrackRender]
    var pair: StretcherPair?

    var trackIDs: [String] {
        tracks.map(\.id)
    }
}

/// How a track list groups by transposition and table, and which previous group each new one carries on from.
enum RecordingGroupPlan {
    struct Group {
        let transposeSemitones: Double
        /// The table of the group's own, or nil for the shared one.
        let segments: [RecordingSegment]?
        let trackIndices: [Int]
        /// The previous group whose pair and reading this one takes over, if any.
        let continues: Int?
        /// The group it carries on from had another transposition, table or tracks, or one of its tracks now reads
        /// another file or at another offset: the render restarts it, primed and retuned, and crossfades.
        let restarts: Bool
    }

    /// What tracks must share to share a group: a stretcher is fed one input against one target timeline, so tracks
    /// group by transposition and by table — equal tables of their own together, and the shared table's apart from
    /// them.
    private struct Key: Equatable {
        let transposeSemitones: Double
        let segments: [RecordingSegment]?
    }

    /// Groups in the order their transposition and table first appear, `tables[i]` being track `i`'s own table (nil:
    /// the shared one). A group carries on from the previous group that held the most of its tracks (on a tie, the one
    /// that held its first track): a stem keeps its stretcher when the reader's transposition moves every stem, rather
    /// than handing it to whichever stem now has its old value. Failing that, it takes a previous group of its
    /// transposition whose tracks have all gone. Each previous group is carried on by one group at most.
    static func make(
        tracks: [RecordingTrackRender], tables: [[RecordingSegment]?], previous: [RecordingGroupLayout],
    ) -> [Group] {
        var keys: [Key] = []
        var members: [[Int]] = []
        for (index, track) in tracks.enumerated() {
            let key = Key(transposeSemitones: track.transposeSemitones, segments: tables[index])
            if let group = keys.firstIndex(of: key) {
                members[group].append(index)
            } else {
                keys.append(key)
                members.append([index])
            }
        }
        let memberIDs = members.map { $0.map { tracks[$0].id } }
        let previousIDs = previous.map(\.trackIDs)
        var taken = Set<Int>()
        var continues = [Int?](repeating: nil, count: keys.count)
        for group in keys.indices {
            var best: (index: Int, rank: (shared: Int, holdsFirst: Int))?
            for candidate in previous.indices where !taken.contains(candidate) {
                let shared = memberIDs[group].count(where: { previousIDs[candidate].contains($0) })
                guard shared > 0 else { continue }
                let rank = (shared: shared, holdsFirst: previousIDs[candidate].contains(memberIDs[group][0]) ? 1 : 0)
                if let current = best, current.rank >= rank { continue }
                best = (candidate, rank)
            }
            if let best {
                taken.insert(best.index)
                continues[group] = best.index
            }
        }
        let present = Set(tracks.map(\.id))
        for group in continues.indices where continues[group] == nil {
            let match = previous.indices.first { candidate in
                !taken.contains(candidate) && previous[candidate].transposeSemitones == keys[group].transposeSemitones
                    && !previousIDs[candidate].contains(where: present.contains)
            }
            if let match {
                taken.insert(match)
                continues[group] = match
            }
        }
        return keys.indices.map { group in
            let restarts = continues[group].map { index in
                previous[index].transposeSemitones != keys[group].transposeSemitones
                    || Set(previousIDs[index]) != Set(memberIDs[group])
                    || !readsTheSameInput(
                        previous[index], members[group].map { tracks[$0] }, segments: keys[group].segments,
                    )
            } ?? false
            return Group(
                transposeSemitones: keys[group].transposeSemitones, segments: keys[group].segments,
                trackIndices: members[group], continues: continues[group], restarts: restarts,
            )
        }
    }

    /// Whether the group reads what `layout` read: the same table, and every track in `tracks` that `layout` already
    /// held the same file at the same offset. What the stretcher is fed is each track's file read at its offset, so a
    /// change to either is a jump in its input; and a new table restarts it too, so the change is heard through the
    /// crossfade rather than as whatever the stretcher had already been fed.
    private static func readsTheSameInput(
        _ layout: RecordingGroupLayout, _ tracks: [RecordingTrackRender], segments: [RecordingSegment]?,
    ) -> Bool {
        guard layout.segments == segments else { return false }
        return tracks.allSatisfy { track in
            guard let held = layout.tracks.first(where: { $0.id == track.id }) else { return true }
            return held.recording === track.recording && held.offsetSeconds == track.offsetSeconds
        }
    }
}

/// The stretched reading's buffers: the input it builds for a stretcher, and each stretcher's output. Allocated on the
/// main actor, sized for any rate up to `sizedRate`, and written only by the render thread once handed over.
final class StretchScratch {
    /// The highest rate the buffers are sized for. Above it a group whose seek no longer fits is read directly.
    static let sizedRate = 2.0
    /// The most output frames one `process` call covers.
    static let runFrames = 4096

    let inputCapacity: Int
    let outputCapacity: Int
    let inputLeft: UnsafeMutablePointer<Float>
    let inputRight: UnsafeMutablePointer<Float>
    /// Stretcher 0's left and right, then stretcher 1's, `outputCapacity` frames each.
    private let outputs: UnsafeMutablePointer<Float>

    init(inputCapacity: Int, outputCapacity: Int = runFrames) {
        self.inputCapacity = inputCapacity
        self.outputCapacity = outputCapacity
        inputLeft = .allocate(capacity: inputCapacity)
        inputLeft.initialize(repeating: 0, count: inputCapacity)
        inputRight = .allocate(capacity: inputCapacity)
        inputRight.initialize(repeating: 0, count: inputCapacity)
        outputs = .allocate(capacity: 4 * outputCapacity)
        outputs.initialize(repeating: 0, count: 4 * outputCapacity)
    }

    deinit {
        inputLeft.deallocate()
        inputRight.deallocate()
        outputs.deallocate()
    }

    func outputLeft(_ voice: Int) -> UnsafeMutablePointer<Float> {
        outputs + 2 * voice * outputCapacity
    }

    func outputRight(_ voice: Int) -> UnsafeMutablePointer<Float> {
        outputs + (2 * voice + 1) * outputCapacity
    }

    /// The input frames `stretcher` can be asked for at up to `sizedRate`: a seek, or a run's input with the cursor
    /// correction's half again on top.
    static func inputCapacity(for stretcher: any RecordingStretcher) -> Int {
        max(stretcher.seekLength(rate: sizedRate), Int((Double(runFrames) * sizedRate * 1.5).rounded(.up)) + 2)
    }
}
