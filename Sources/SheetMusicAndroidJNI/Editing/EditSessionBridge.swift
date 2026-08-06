import Foundation
import SheetMusicCore

/// Edit-session JNI bridge. A host that is editing keeps the authoritative score in its own image and relays each
/// applied intent here, so the score behind this handle stays byte-identical and only the layout has to be recomputed
/// — no new handle, no re-parse, and every downstream consumer of the handle (MIDI render, timeline, cursor) keeps
/// working across an edit.
///
/// The session lives beside the score rather than inside it so a host that never edits pays nothing.
///
/// Sessions are keyed by the score handle they mirror rather than held in the generic `HandleTable`, because the key
/// is the caller's existing score handle, not a new one.
///
/// ## Thread safety
///
/// Every mutating entry point below (`nativeBeginEditSession`, `nativeApplyEditIntent`, `nativeEditUndo`,
/// `nativeEditRedo`, `nativeEndEditSession`) holds `editSessionsLock` for the *entire* operation: looking up the
/// session, calling into `ScoreEditSession` (which is not itself thread-safe — see its doc comment), and publishing
/// the result back into `scoreTable` / `LayoutDocumentCache`. A JNI entry point can be reached from any thread, so
/// "Kotlin only ever drives one session from one thread" is a fact about today's caller, not a contract this file
/// can lean on. Holding one lock across the whole operation is what keeps the session mutation and the two caches it
/// touches consistent with each other regardless of the caller's threading, at the cost of serializing edits across
/// *different* handles too — two hosts editing two different scores at once would contend on this lock. That cost is
/// negligible: edits are user-paced, nowhere near the rate where lock contention would be measurable, and the
/// alternative (documenting an unenforced single-thread-per-handle rule) is the kind of contract that only gets
/// noticed once it's already been violated.
private nonisolated(unsafe) var editSessions: [Int64: ScoreEditSession] = [:]
private let editSessionsLock = NSLock()

private func withLock<T>(_ body: () -> T) -> T {
    editSessionsLock.lock()
    defer { editSessionsLock.unlock() }
    return body()
}

/// Opens a mirror edit session over the score behind `scoreHandle`. Returns `false` for an unknown handle.
/// Idempotent: opening twice replaces the session, which is what a host restarting a session wants.
public func nativeBeginEditSession(scoreHandle: Int64) -> Bool {
    withLock {
        guard let score = scoreTable.value(for: scoreHandle) else { return false }
        editSessions[scoreHandle] = ScoreEditSession(score: score)
        return true
    }
}

/// Applies one relayed intent. Returns `false` when there is no session, the bytes don't decode, or the engine
/// refuses the edit — all three leave the score untouched, which is exactly what the authoritative side did too.
public func nativeApplyEditIntent(scoreHandle: Int64, intentBytes: Data) -> Bool {
    withLock {
        guard let session = editSessions[scoreHandle] else { return false }
        guard let intent = try? EditIntentCodec.decode(intentBytes) else { return false }
        guard session.apply(intent) else { return false }
        publish(session.score, to: scoreHandle)
        return true
    }
}

/// Undoes the session's last applied intent. Returns `false` when there is no session or nothing to undo.
public func nativeEditUndo(scoreHandle: Int64) -> Bool {
    withLock {
        guard let session = editSessions[scoreHandle], session.undo() else { return false }
        publish(session.score, to: scoreHandle)
        return true
    }
}

/// Redoes the session's last undone intent. Returns `false` when there is no session or nothing to redo.
public func nativeEditRedo(scoreHandle: Int64) -> Bool {
    withLock {
        guard let session = editSessions[scoreHandle], session.redo() else { return false }
        publish(session.score, to: scoreHandle)
        return true
    }
}

/// Drops the session. The score keeps whatever the session last wrote — ending a session is not a revert.
public func nativeEndEditSession(scoreHandle: Int64) {
    withLock { editSessions[scoreHandle] = nil }
}

/// The digest the host compares against its own copy. `0` for an unknown handle — a value no real score produces
/// often enough to matter, and the host treats "unknown handle" as a mismatch anyway.
public func nativeScoreFingerprint(scoreHandle: Int64) -> Int64 {
    guard let score = scoreTable.value(for: scoreHandle) else { return 0 }
    return score.stableFingerprint
}

/// This image's build identity. A host compares it with its own before opening a session.
public func nativeEngineVersionStamp() -> Int64 {
    SheetMusicEngine.versionStamp
}

/// Writes the mutated score back into the handle and drops the stale layout, so the next `nativeComputeLayout`
/// re-engraves. Everything downstream keys off the same handle, which is the point of mirroring rather than
/// reloading. Called only from inside a `withLock` block above — see this file's "Thread safety" note.
private func publish(_ score: Score, to scoreHandle: Int64) {
    scoreTable.replace(scoreHandle, with: score)
    LayoutDocumentCache.release(scoreHandle)
}
