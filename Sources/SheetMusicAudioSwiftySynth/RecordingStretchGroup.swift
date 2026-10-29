import SheetMusicAudioApple
import SheetMusicAudioCore

// The recordings that share one transposition, read through one stretcher pair when the rate is not 100 % or the
// transposition is not 0 (`SwiftySynthBackend+Stretch.swift`). The pair and the scratch are made on the main actor and
// handed to the render thread in a lock swap; the render thread only calls them.

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
    /// The group's transposition changed: the next frame that plays is a jump to a stretcher retuned for it.
    var needsRetune = false

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
        needsRetune = false
    }
}

/// One group as the render thread reads it.
struct RecordingStretchGroup {
    let transposeSemitones: Double
    /// Indices into `PlaybackAlignmentState.tracks`.
    let trackIndices: [Int]
    /// Nil until a stretcher is needed and the backend has a factory; the group is then read directly.
    var pair: StretcherPair?
    var state = StretchGroupState()
}

/// The main actor's copy of a group: what it holds and its pair, so a new track list or rate can be planned and its
/// stretchers made before the lock, without reading the render thread's state.
struct RecordingGroupLayout {
    let transposeSemitones: Double
    let trackIDs: [String]
    var pair: StretcherPair?
}

/// How a track list groups by transposition, and which previous group each new one carries on from.
enum RecordingGroupPlan {
    struct Group {
        let transposeSemitones: Double
        let trackIndices: [Int]
        /// The previous group whose pair and reading this one takes over, if any.
        let continues: Int?
    }

    /// Groups in the order their transposition first appears. A group carries on from the previous group with the same
    /// transposition; failing that, from the previous group its first track was in (a transposition change, which the
    /// render then crossfades to a retuned stretcher). Each previous group is carried on by one group at most.
    static func make(tracks: [RecordingTrackRender], previous: [RecordingGroupLayout]) -> [Group] {
        var transpositions: [Double] = []
        var members: [[Int]] = []
        for (index, track) in tracks.enumerated() {
            if let group = transpositions.firstIndex(of: track.transposeSemitones) {
                members[group].append(index)
            } else {
                transpositions.append(track.transposeSemitones)
                members.append([index])
            }
        }
        var taken = Set<Int>()
        var continues = transpositions.map { transposition -> Int? in
            guard let match = previous.firstIndex(where: { $0.transposeSemitones == transposition }) else { return nil }
            taken.insert(match)
            return match
        }
        for group in continues.indices where continues[group] == nil {
            let firstID = tracks[members[group][0]].id
            let match = previous.indices.first { !taken.contains($0) && previous[$0].trackIDs.contains(firstID) }
            if let match {
                taken.insert(match)
                continues[group] = match
            }
        }
        return transpositions.indices.map { group in
            Group(transposeSemitones: transpositions[group], trackIndices: members[group], continues: continues[group])
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
