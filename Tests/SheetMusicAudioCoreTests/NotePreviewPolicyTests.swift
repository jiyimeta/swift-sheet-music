@testable import SheetMusicAudioCore
import Testing

/// The contract both playback engines execute. Every case here was a bug on one platform or the other before the
/// decisions were pulled into one place, which is why they are pinned as behaviour rather than as arithmetic.
struct NotePreviewPolicyTests {
    private let middleC = PreviewVoice(channel: 0, pitch: 60)
    private let g = PreviewVoice(channel: 0, pitch: 67)
    private let crash = PreviewVoice(channel: 9, pitch: 49)
    private let kick = PreviewVoice(channel: 9, pitch: 36)

    private func plan(
        _ policy: inout NotePreviewPolicy,
        _ voice: PreviewVoice,
        isDrum: Bool = false,
        ring: Int = 500,
    ) -> PreviewPlan {
        policy.begin(voice: voice, velocity: 96, isDrum: isDrum, ringMilliseconds: ring)
    }

    @Test func theFirstAuditionSupersedesNothing() {
        var policy = NotePreviewPolicy()
        let first = plan(&policy, middleC)
        #expect(first.supersededVoices.isEmpty)
        #expect(first.voices == [middleC])
        #expect(policy.soundingVoices == [middleC])
    }

    @Test func aSecondAuditionSupersedesTheFirst() {
        var policy = NotePreviewPolicy()
        _ = plan(&policy, middleC)
        let second = plan(&policy, g)
        #expect(second.supersededVoices == [middleC])
        #expect(policy.soundingVoices == [g])
    }

    /// The audible half of the Android bug: the superseded note's end fired on its own schedule and silenced the
    /// note that had replaced it. It only struck when the two shared a channel and pitch, so it presented as
    /// previews going intermittently missing while notes were entered quickly.
    @Test func aSupersededEndSilencesNothing() {
        var policy = NotePreviewPolicy()
        let first = plan(&policy, middleC)
        let second = plan(&policy, middleC)

        #expect(policy.endVoices(generation: first.generation).isEmpty)
        #expect(policy.soundingVoices == [middleC], "the surviving audition must still be sounding")
        #expect(policy.endVoices(generation: second.generation) == [middleC])
    }

    @Test func anUnsupersededAuditionEndsOnItsOwnNote() {
        var policy = NotePreviewPolicy()
        let only = plan(&policy, g)
        #expect(policy.endVoices(generation: only.generation) == [g])
        #expect(policy.soundingVoices.isEmpty)
    }

    @Test func endingTwiceOnTheSameGenerationIsHarmless() {
        var policy = NotePreviewPolicy()
        let only = plan(&policy, g)
        _ = policy.endVoices(generation: only.generation)
        #expect(policy.endVoices(generation: only.generation).isEmpty)
    }

    /// Deferred work — parking the audio graph — asks this rather than `end`, because it must not consume the
    /// audition it is asking about.
    @Test func currencyOutlivesTheNoteOff() {
        var policy = NotePreviewPolicy()
        let only = plan(&policy, middleC)
        _ = policy.endVoices(generation: only.generation)
        #expect(policy.isCurrent(generation: only.generation), "the graph is still rendering this note's release")

        let next = plan(&policy, g)
        #expect(!policy.isCurrent(generation: only.generation), "a newer audition wants the graph kept running")
        #expect(policy.isCurrent(generation: next.generation))
    }

    @Test func aDrumRingsForItsDecayRatherThanTheDurationAskedFor() {
        var policy = NotePreviewPolicy()
        #expect(plan(&policy, middleC, ring: 500).ringMilliseconds == 500)
        #expect(plan(&policy, middleC, isDrum: true, ring: 500).ringMilliseconds
            == NotePreviewPolicy.drumRingMilliseconds)
    }

    @Test func everyAuditionCarriesTheSameReleaseTail() {
        var policy = NotePreviewPolicy()
        #expect(plan(&policy, middleC).releaseTailMilliseconds == NotePreviewPolicy.releaseTailMilliseconds)
        #expect(plan(&policy, middleC, isDrum: true).releaseTailMilliseconds
            == NotePreviewPolicy.releaseTailMilliseconds)
    }

    @Test func silencingReportsTheSoundingNoteAndSupersedesItsEnd() {
        var policy = NotePreviewPolicy()
        let only = plan(&policy, middleC)
        #expect(policy.silenceVoices() == [middleC])
        #expect(policy.soundingVoices.isEmpty)
        #expect(!policy.isCurrent(generation: only.generation), "teardown must cancel work already scheduled")
        #expect(policy.silenceVoices().isEmpty)
    }

    // MARK: - Several notes struck together

    /// A tap on a drum beat written as hands over feet: the cymbal and the kick are one audition.
    @Test func severalNotesAreOneAudition() throws {
        var policy = NotePreviewPolicy()
        let planned = policy.begin(voices: [crash, kick], velocity: 96, isDrum: true, ringMilliseconds: 500)
        let beat = try #require(planned)
        #expect(beat.voices == [crash, kick])
        #expect(policy.soundingVoices == [crash, kick])
        #expect(policy.endVoices(generation: beat.generation) == [crash, kick])
        #expect(policy.soundingVoices.isEmpty)
    }

    /// The next tap has to cut the whole beat it replaces, not only the note that came first.
    @Test func theNextAuditionSupersedesEveryNoteOfTheLast() {
        var policy = NotePreviewPolicy()
        _ = policy.begin(voices: [crash, kick], velocity: 96, isDrum: true, ringMilliseconds: 500)
        let next = plan(&policy, middleC)
        #expect(next.supersededVoices == [crash, kick])
    }

    @Test func silencingReportsEveryNoteOfTheAudition() {
        var policy = NotePreviewPolicy()
        _ = policy.begin(voices: [middleC, g], velocity: 96, isDrum: false, ringMilliseconds: 500)
        #expect(policy.silenceVoices() == [middleC, g])
    }

    /// Two voices can strike the same key — a unison, or the same drum in both voices.
    @Test func aKeyNamedTwiceIsStruckOnce() throws {
        var policy = NotePreviewPolicy()
        let planned = policy.begin(voices: [middleC, g, middleC], velocity: 96, isDrum: false, ringMilliseconds: 500)
        let unison = try #require(planned)
        #expect(unison.voices == [middleC, g])
    }

    /// A beat that starts nothing — a rest no other voice fills — sounds nothing and must not cut what is ringing.
    @Test func anEmptyAuditionPlansNothingAndCutsNothing() {
        var policy = NotePreviewPolicy()
        let ringing = plan(&policy, middleC)
        #expect(policy.begin(voices: [], velocity: 96, isDrum: false, ringMilliseconds: 500) == nil)
        #expect(policy.soundingVoices == [middleC])
        #expect(policy.isCurrent(generation: ringing.generation))
    }
}
