import Foundation
import Observation
import SheetMusic

/// Main-actor state for one staff-text, system-text, chord-symbol, or
/// rehearsal-mark entry caret.
@MainActor
@Observable
final class TextInputSession {
    private(set) var kind: TextInputPlanner.Kind = .staffText
    private(set) var anchor: VoiceElementID?
    var text = ""

    var isActive: Bool {
        anchor != nil
    }

    func begin(
        kind: TextInputPlanner.Kind,
        at anchor: VoiceElementID,
        controller: NoteInputController,
    ) {
        self.kind = kind
        self.anchor = anchor
        refill(controller: controller)
    }

    /// Starts text input after closing the mutually-exclusive lyric
    /// session used by the same overlay.
    func begin(
        kind: TextInputPlanner.Kind,
        at anchor: VoiceElementID,
        controller: NoteInputController,
        ending lyricSession: LyricInputSession,
    ) {
        lyricSession.end()
        begin(kind: kind, at: anchor, controller: controller)
    }

    /// Applies the current text and returns the location the host should
    /// reveal. Command refusals propagate to the host unchanged.
    func commit(
        advance: Bool,
        controller: NoteInputController,
        undoManager: UndoManager?,
    ) throws -> VoiceElementID? {
        guard let current = anchor else { return nil }
        let command = TextInputPlanner.command(
            kind,
            at: current,
            text: text.isEmpty ? nil : text,
        )
        try controller.apply(command, undoManager: undoManager)

        guard advance else { return current }
        anchor = TextInputPlanner.nextAnchor(
            kind, after: current, in: controller.score,
        )
        guard anchor != nil else {
            end()
            return current
        }
        refill(controller: controller)
        return anchor
    }

    func end() {
        anchor = nil
        text = ""
    }

    private func refill(controller: NoteInputController) {
        guard let anchor else {
            text = ""
            return
        }
        text = TextInputPlanner.currentText(
            kind, at: anchor, in: controller.score,
        ) ?? ""
    }
}
