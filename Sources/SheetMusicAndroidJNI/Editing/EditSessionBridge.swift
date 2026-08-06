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
/// can lean on. Holding one lock across the whole operation is what this file's five mutating entry points
/// guarantee: they serialize against *each other* (so two of them can never interleave inside `ScoreEditSession`,
/// and a session's apply-then-publish is atomic with respect to a concurrent `nativeBeginEditSession` /
/// `nativeEndEditSession` on the same handle), at the cost of serializing edits across *different* handles too. That
/// cost is negligible: edits are user-paced, nowhere near the rate where lock contention would be measurable.
///
/// It does **not** cover `nativeComputeLayout` (`JNISymbols.swift`), which reads `scoreTable` and writes
/// `LayoutDocumentCache` without taking `editSessionsLock` — so a layout compute racing an edit can still read the
/// pre-edit score and then store its (now-stale) result after the edit's own cache invalidation has already run,
/// leaving a layout built from the old score cached against a handle whose score is new. That race is pre-existing
/// architecture (every other bridge file writes `LayoutDocumentCache` the same unlocked way) and out of scope here;
/// this comment exists so a future reader doesn't assume this lock buys more than it does.
///
/// `publish` reports back whether the write actually landed (see `HandleTable.replace`), so a handle released out
/// from under an in-flight edit — e.g. by a concurrent `nativeReleaseScore` — makes the apply/undo/redo call return
/// `false` instead of claiming success for a mutation that has nowhere to land.
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
/// refuses the edit.
///
/// Unlike a direct `ScoreEditSession.apply`, `false` here is always an anomaly, never a benign no-op. The
/// authoritative side only ever emits an intent it has already applied successfully — a refusal there produces no
/// intent, so nothing gets relayed and this function is never even called for it. Every intent that does reach here
/// was already accepted upstream, which means a `false` return can only mean one of: no session is open, the bytes
/// were corrupted in transit, the handle was released mid-edit, or the two images have already diverged. All four
/// call for a resync, not a shrug — a caller that logs this and moves on is the failure mode this comment exists to
/// head off.
public func nativeApplyEditIntent(scoreHandle: Int64, intentBytes: Data) -> Bool {
    withLock {
        guard let session = editSessions[scoreHandle] else { return false }
        guard let intent = try? EditIntentCodec.decode(intentBytes) else { return false }
        guard session.apply(intent) else { return false }
        return publish(session.score, to: scoreHandle)
    }
}

/// Undoes the session's last applied intent. Returns `false` when there is no session or nothing to undo.
public func nativeEditUndo(scoreHandle: Int64) -> Bool {
    withLock {
        guard let session = editSessions[scoreHandle], session.undo() else { return false }
        return publish(session.score, to: scoreHandle)
    }
}

/// Redoes the session's last undone intent. Returns `false` when there is no session or nothing to redo.
public func nativeEditRedo(scoreHandle: Int64) -> Bool {
    withLock {
        guard let session = editSessions[scoreHandle], session.redo() else { return false }
        return publish(session.score, to: scoreHandle)
    }
}

/// Drops the session. The score keeps whatever the session last wrote — ending a session is not a revert.
/// A no-op for a handle with no session — safe to call unconditionally, which is exactly what
/// `nativeReleaseScore` (`JNISymbols.swift`) does so a session can never outlive the score handle it mirrors.
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
///
/// Returns whatever `HandleTable.replace` reports: `false` when `scoreHandle` was released out from under this
/// call (e.g. a concurrent `nativeReleaseScore`), in which case the layout cache is left untouched too — there is
/// nothing to invalidate for a handle that no longer exists, and the caller's `false` already says the edit didn't
/// land.
@discardableResult
private func publish(_ score: Score, to scoreHandle: Int64) -> Bool {
    guard scoreTable.replace(scoreHandle, with: score) else { return false }
    LayoutDocumentCache.release(scoreHandle)
    return true
}
