import Foundation
import SheetMusic

/// Identifies the pending edit currently represented by the screen-only
/// score and layout. Text participates so every keystroke invalidates it.
enum ScoreTextEntryPreviewIdentity: Hashable {
    case lyric(cursor: LyricInputPlanner.Cursor, text: String)
    case text(kind: Int, anchor: VoiceElementID, text: String)
}

/// Composes committed score state with the active inline editor's pending
/// text. The command is applied only to a value copy; failures fall back to
/// the committed value and never interrupt rendering.
@MainActor
enum ScoreTextEntryPreview {
    static func identity(
        lyricSession: LyricInputSession,
        textSession: TextInputSession,
    ) -> ScoreTextEntryPreviewIdentity? {
        if let cursor = lyricSession.cursor {
            return .lyric(cursor: cursor, text: lyricSession.text)
        }
        if let anchor = textSession.anchor {
            return .text(
                kind: textSession.kind.overlayIdentity,
                anchor: anchor,
                text: textSession.text,
            )
        }
        return nil
    }

    static func compose(
        committed: Score,
        lyricSession: LyricInputSession,
        textSession: TextInputSession,
    ) -> Score {
        if let cursor = lyricSession.cursor {
            let plan = LyricInputPlanner.plan(
                typing: lyricSession.text,
                terminatedBy: .none,
                at: cursor,
                in: committed,
            )
            return applying(plan.command, to: committed)
        }
        if let anchor = textSession.anchor {
            let trimmed = textSession.text.trimmingCharacters(
                in: .whitespacesAndNewlines,
            )
            if trimmed.isEmpty,
               TextInputPlanner.currentText(
                   textSession.kind,
                   at: anchor,
                   in: committed,
               ) == nil
            {
                return committed
            }
            let command = TextInputPlanner.command(
                textSession.kind,
                at: anchor,
                text: trimmed.isEmpty ? nil : textSession.text,
            )
            return applying(command, to: committed)
        }
        return committed
    }

    private static func applying(
        _ command: (any EditCommand)?,
        to committed: Score,
    ) -> Score {
        guard let command else { return committed }
        var preview = committed
        do {
            _ = try command.apply(to: &preview)
            return preview
        } catch {
            return committed
        }
    }
}
