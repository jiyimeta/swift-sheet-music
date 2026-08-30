@testable import SheetMusicAudioCore
import Testing

/// The contract both playback engines execute. Every case here was a bug on one platform or the other before the
/// decisions were pulled into one place, which is why they are pinned as behaviour rather than as arithmetic.
struct NotePreviewPolicyTests {
    private let middleC = PreviewVoice(channel: 0, pitch: 60)
    private let g = PreviewVoice(channel: 0, pitch: 67)

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
        #expect(first.supersedes == nil)
        #expect(first.voice == middleC)
        #expect(policy.sounding == middleC)
    }

    @Test func aSecondAuditionSupersedesTheFirst() {
        var policy = NotePreviewPolicy()
        _ = plan(&policy, middleC)
        let second = plan(&policy, g)
        #expect(second.supersedes == middleC)
        #expect(policy.sounding == g)
    }

    /// The audible half of the Android bug: the superseded note's end fired on its own schedule and silenced the
    /// note that had replaced it. It only struck when the two shared a channel and pitch, so it presented as
    /// previews going intermittently missing while notes were entered quickly.
    @Test func aSupersededEndSilencesNothing() {
        var policy = NotePreviewPolicy()
        let first = plan(&policy, middleC)
        let second = plan(&policy, middleC)

        #expect(policy.end(generation: first.generation) == nil)
        #expect(policy.sounding == middleC, "the surviving audition must still be sounding")
        #expect(policy.end(generation: second.generation) == middleC)
    }

    @Test func anUnsupersededAuditionEndsOnItsOwnNote() {
        var policy = NotePreviewPolicy()
        let only = plan(&policy, g)
        #expect(policy.end(generation: only.generation) == g)
        #expect(policy.sounding == nil)
    }

    @Test func endingTwiceOnTheSameGenerationIsHarmless() {
        var policy = NotePreviewPolicy()
        let only = plan(&policy, g)
        _ = policy.end(generation: only.generation)
        #expect(policy.end(generation: only.generation) == nil)
    }

    /// Deferred work — parking the audio graph — asks this rather than `end`, because it must not consume the
    /// audition it is asking about.
    @Test func currencyOutlivesTheNoteOff() {
        var policy = NotePreviewPolicy()
        let only = plan(&policy, middleC)
        _ = policy.end(generation: only.generation)
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
        #expect(policy.silence() == middleC)
        #expect(policy.sounding == nil)
        #expect(!policy.isCurrent(generation: only.generation), "teardown must cancel work already scheduled")
        #expect(policy.silence() == nil)
    }
}
