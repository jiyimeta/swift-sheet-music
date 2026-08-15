@testable import SheetMusicCore
import Testing

/// The Android JNI process has no main-actor executor: a `@MainActor` hop from a JNI entry point is scheduled and
/// never resumed. `ScoreEditor` therefore has to be drivable from a plain synchronous nonisolated context, which is
/// exactly what this suite is — no `@MainActor` annotation, no `await`.
@Suite("ScoreEditor off the main actor")
struct ScoreEditorOffMainActorTests {
    @Test("a nonisolated caller can construct and drive the editor")
    func drivesFromNonisolatedContext() throws {
        let editor = ScoreEditor(score: EditingFixtures.fourQuarterRests())
        try editor.apply(InputNote(
            at: RestID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 1,
            ),
            pitch: 60,
            tpc: 14,
        ))
        #expect(editor.canUndo)
        try editor.undo()
        #expect(editor.canUndo == false)
        #expect(editor.canRedo)
    }
}
