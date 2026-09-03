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

    /// SP0/SP1's original chain: twenty-three note- and slot-level steps over `EditingFixtures.replayFixture()`.
    static let standard = ReplayChain(
        name: "standard",
        androidAssetDir: "editReplay",
        webFixtureStem: "edit-replay",
        fixture: { EditingFixtures.replayFixture() },
        steps: { EditReplayScript.standard(staff: $0) },
        minimumDistinctFingerprints: 10,
    )

    /// The edit-command parity project's chain: eighty-eight steps over `EditingFixtures.parityFixture()` covering
    /// intents 30…72 — the structural group in steps 1…10, the range group in steps 11…19, the mark group in
    /// steps 20…40, the note / chord group in steps 41…61, the visibility group in steps 64…72 (prepared by
    /// two `inputNote`s in steps 62 / 63) and the spanner group in steps 73…88 — which the standard chain
    /// predates and therefore never encodes.
    static let parity = ReplayChain(
        name: "parity",
        androidAssetDir: "editReplay-parity",
        webFixtureStem: "edit-replay-parity",
        fixture: { EditingFixtures.parityFixture() },
        steps: { EditReplayScript.parity(staff: $0) },
        // Actual is 58 of 89 recorded values as of the spanner group (62-72) landing — the twelve the group adds
        // on top of the 46 the visibility group left. The floor keeps the margin group 5 chose when it replaced a
        // floor sitting exactly ON the actual: four below, tight enough that the spanner steps are load-bearing,
        // loose enough not to flake on a harmless coincidence.
        minimumDistinctFingerprints: 54,
    )

    static let all: [ReplayChain] = [.standard, .parity]
}
