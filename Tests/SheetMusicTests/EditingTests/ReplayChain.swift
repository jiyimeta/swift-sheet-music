import Foundation
@testable import SheetMusicCore
import Testing

/// One end-to-end replay chain: a fixture, a script over it, and the two places its recorded output lives (an
/// Android instrumented-test asset directory and a pair of web fixture files).
///
/// The three replay suites — `EditReplayGoldenTests` (JNI wire bytes), `EditReplayWebGoldenTests` (web fixture
/// JSON, cross-checked against the Android goldens) and `EditReplayDeterminismTests` (two host sessions agreeing)
/// — are each parameterized over `all`, so adding a chain here adds it to every suite at once rather than
/// duplicating three near-identical tests per chain. Every path a suite touches (`assetsDir`, the web fixture
/// stems, the Android `goldens.txt` it cross-checks, the fixture builder, the distinct-fingerprint floor) is read
/// off the chain rather than hard-coded, which is what makes the parameterization total: a suite that still named
/// `editReplay/` directly would silently verify the standard chain twice.
struct ReplayChain: Sendable, CustomTestStringConvertible {
    /// Identifies the chain in test output; also the only thing `testDescription` shows, so it has to be short.
    let name: String
    /// Directory name under `Android/SheetMusicAndroid/src/androidTest/assets/`.
    let androidAssetDir: String
    /// Basename (no extension) of the chain's `Web/sheet-music-web/test/fixtures/` `.mscx` / `.json` pair.
    let webFixtureStem: String
    /// Builds a fresh score for the chain. A closure rather than a stored `Score` so every consumer starts from an
    /// independent value — the determinism test seeds two sessions and must not hand them the same instance.
    let fixture: @Sendable () -> Score
    /// The chain's steps, over the staff the caller nominates as the primary one (part 0, staff 0 in practice).
    let steps: @Sendable (StaffAddress) -> [EditReplayStep]
    /// How much fingerprint spread the chain must show. A script every step of which got refused would produce a
    /// flat sequence and "prove" determinism trivially; this floor rules that out. It is per-chain because the
    /// chains differ in length and in how many of their steps are deliberate no-ops on the fingerprint.
    let minimumDistinctFingerprints: Int

    var testDescription: String {
        name
    }

    /// `fixture()`, with every element identified before the caller ever
    /// encodes it — for a byte-stable golden MSCX comparison.
    ///
    /// `fixture()` returns every element unassigned, and `MSCXEncoder.encode`'s
    /// last-resort fill (`MSCXEncoder.swift`) mints gaps from a fresh
    /// `EIDAllocator()`, whose actor is drawn at random per process
    /// (`EIDAllocator.init()`). Since Chord/Rest/Note write `<eid>` for a v4
    /// target, encoding the bare `fixture()` twice — once now, once on the
    /// next `swift test` invocation — would write two different (but
    /// equally valid) sets of identifiers, and the committed `fixture.mscx`
    /// / web `.mscx` goldens could never compare byte-identical across runs.
    /// A fixed, non-sentinel actor makes the assignment (and so the
    /// resulting bytes) the same on every call.
    func identifiedFixture() -> Score {
        var score = fixture()
        var allocator = EIDAllocator(actor: 1)
        score.assignMissingIDs(using: &allocator)
        return score
    }

    /// SP0/SP1's original chain: twenty-three note- and slot-level steps over `EditingFixtures.replayFixture()`.
    static let standard = ReplayChain(
        name: "standard",
        androidAssetDir: "editReplay",
        webFixtureStem: "edit-replay",
        fixture: { EditingFixtures.replayFixture() },
        steps: { EditReplayScript.standard(staff: $0) },
        minimumDistinctFingerprints: 10,
    )

    /// The edit-command parity project's chain: ninety-two steps over `EditingFixtures.parityFixture()` covering
    /// every intent the project appended, 30…73 — the structural group in steps 1…10, the range group in steps
    /// 11…19, the mark group in steps 20…40, the note / chord group in steps 41…61, the visibility group in steps
    /// 64…72 (prepared by two `inputNote`s in steps 62 / 63), the spanner group in steps 73…88 and the harmony
    /// group in steps 89…92 — which the standard chain predates and therefore never encodes.
    ///
    /// FROZEN, like `standard`, since intent 73 landed: the catalogue is complete, so this chain is never extended
    /// and never re-recorded. A `step-N.bin`, `goldens.txt` line or `edit-replay-parity.json` byte that changes is
    /// a wire or fingerprint regression to fix, not a golden to refresh — the same reading `EditReplayGoldenTests`
    /// gives the standard chain. A future intent family starts a third chain.
    static let parity = ReplayChain(
        name: "parity",
        androidAssetDir: "editReplay-parity",
        webFixtureStem: "edit-replay-parity",
        fixture: { EditingFixtures.parityFixture() },
        steps: { EditReplayScript.parity(staff: $0) },
        // Actual is 61 of 93 recorded values as of the harmony group (73) landing and the chain freezing — the
        // three the group adds on top of the 58 the spanner group left. The floor keeps the margin group 5 chose
        // when it replaced a floor sitting exactly ON the actual: four below, tight enough that the harmony steps
        // are load-bearing, loose enough not to flake on a harmless coincidence.
        minimumDistinctFingerprints: 57,
    )

    /// The macOS score-text-entry project's chain (spec 2026-09-07): fifteen steps over
    /// `EditingFixtures.twoConsecutiveC4Chords()` covering both intents this project appended —
    /// `setLyricSyllables` (74) in steps 1…6 and `setTextVisible` (75) in steps 7…15. A third chain rather than a
    /// fifth group on `.parity`: see `EditReplayScript.lyrics`'s own doc comment for why `.parity`'s freeze does
    /// not extend to it, and for why 75 extended this chain instead of starting a fourth.
    ///
    /// NOT frozen, unlike `standard` and `parity`: this project's catalogue is still open, so a further intent of
    /// its own appends steps here. What that costs is stated where it is paid — appending never rewrites an
    /// existing `step-N.bin` or `goldens.txt` line, so a byte that DOES change under a recording is still a
    /// regression to read rather than a golden to refresh.
    static let lyrics = ReplayChain(
        name: "lyrics",
        androidAssetDir: "editReplay-lyrics",
        webFixtureStem: "edit-replay-lyrics",
        fixture: { EditingFixtures.twoConsecutiveC4Chords() },
        steps: { EditReplayScript.lyrics(staff: $0) },
        // Actual is 12 of 16 recorded values (steps 3/4 and 9/10 each repeat an earlier one) — one below the
        // actual, the margin the chain chose when it was six steps long.
        minimumDistinctFingerprints: 11,
    )

    /// The selection-and-editing project's accepting-path chain for intents 76...79, extended by the
    /// properties-inspector project to 80...83. The script documents its state transitions, three-state font
    /// patch and hand-derived fingerprint floor.
    static let properties = ReplayChain(
        name: "properties",
        androidAssetDir: "editReplay-properties",
        webFixtureStem: "edit-replay-properties",
        fixture: { EditingFixtures.twoConsecutiveC4Chords() },
        steps: { EditReplayScript.properties(staff: $0) },
        // Initial state + seven new states from intents 76...79, plus two from the note flags (80/81) appended
        // for the properties-inspector project: `Note.isSmall` and `Note.play` are hashed, so each of steps 12
        // and 13 introduces a new state. The three offset / auto-place steps (82/83, steps 15...17) add recorded
        // steps and no distinct fingerprints — neither field is hashed, deliberately (see
        // `ElementPropertyFingerprintTests`). No recorded count supplies this floor: each of the nine authored
        // changes that do move the fingerprint must contribute to the expected spread.
        minimumDistinctFingerprints: 10,
    )

    static let all: [ReplayChain] = [.standard, .parity, .lyrics, .properties]
}
