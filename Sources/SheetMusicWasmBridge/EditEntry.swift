import JavaScriptKit
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicFoundation

/// The structured edit outcome surfaced to JavaScript.
///
/// BridgeJS's throwing export would collapse the refusal into one message, so
/// edit entry points return this value instead.
@JS public struct EditOutcome {
    public var accepted: Bool
    public var code: String
    public var operation: String
    public var message: String

    public init(accepted: Bool, code: String, operation: String, message: String) {
        self.accepted = accepted
        self.code = code
        self.operation = operation
        self.message = message
    }
}

/// The current state of the edit session keyed by a score handle.
///
/// `lastAffected*` fields are `-1` when `hasLastAffected == false`.
@JS public struct EditSessionState {
    public var active: Bool
    public var canUndo: Bool
    public var canRedo: Bool
    public var hasLastAffected: Bool
    public var lastAffectedPartIndex: Int
    public var lastAffectedStaffIndexInPart: Int
    public var lastAffectedMeasureIndex: Int
    public var lastAffectedVoiceIndex: Int
    public var lastAffectedElementIndex: Int

    public init(
        active: Bool,
        canUndo: Bool,
        canRedo: Bool,
        hasLastAffected: Bool,
        lastAffectedPartIndex: Int,
        lastAffectedStaffIndexInPart: Int,
        lastAffectedMeasureIndex: Int,
        lastAffectedVoiceIndex: Int,
        lastAffectedElementIndex: Int,
    ) {
        self.active = active
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.hasLastAffected = hasLastAffected
        self.lastAffectedPartIndex = lastAffectedPartIndex
        self.lastAffectedStaffIndexInPart = lastAffectedStaffIndexInPart
        self.lastAffectedMeasureIndex = lastAffectedMeasureIndex
        self.lastAffectedVoiceIndex = lastAffectedVoiceIndex
        self.lastAffectedElementIndex = lastAffectedElementIndex
    }
}

/// Edit sessions keyed by the score handle a browser host already owns.
///
/// This mirrors Android's `EditSessionBridge` handle-keyed lifetime but not its
/// whole-operation lock. JNI entry points can arrive on arbitrary threads, so
/// Android serializes lookup, `ScoreEditSession` mutation and publish under one
/// `NSLock`. wasm32-wasip1 is single-threaded: every exported function runs to
/// completion on the JavaScript main thread, and no other entry point can
/// interleave in the middle of an apply/undo/redo. The table is still wrapped in
/// the same `SerialLock` idiom as `LayoutDocumentCache` and `PlaybackClockCache`
/// to satisfy Swift 6's global-mutable-state rules with real serialization.
///
/// A future Worker layout path should keep this invariant by using a separate
/// wasm instance per Worker, not shared-memory threads. If this target ever
/// adopts shared-memory wasm threads, this file must be redesigned instead of
/// treating the table lock as operation-level protection.
private nonisolated(unsafe) var editSessions: [Int64: ScoreEditSession] = [:]
private let editSessionsLock = SerialLock(label: "SheetMusicWasmBridge.editSessions")

private func withEditSessions<T>(_ body: () -> T) -> T {
    editSessionsLock.withLock(body)
}

/// Android: `nativeBeginEditSession`. Idempotent; re-begin replaces the session
/// and drops its undo stack.
@JS public func beginEditSession(handle: Int) -> Bool {
    let scoreHandle = Int64(handle)
    guard let score = scoreTable.value(for: scoreHandle) else { return false }
    withEditSessions {
        editSessions[scoreHandle] = ScoreEditSession(score: score)
    }
    return true
}

/// Android: `nativeEndEditSession`. Not a revert; a no-op without a session.
@JS public func endEditSession(handle: Int) {
    releaseEditSession(handle: Int64(handle))
}

/// Android: `nativeEditUndo`, but returns the outcome channel so an empty stack
/// carries `edit.nothingToUndo`.
///
/// `ScoreEditSession.undo()` answers `false` for two unrelated reasons — an
/// empty stack, and an inverse command that failed to apply — and records
/// neither in `lastRefusal`, which only `apply` sets. Collapsing both into
/// `edit.nothingToUndo` would report the second, a genuine engine bug, as the
/// benign one, and a host would show "nothing to undo" over a visibly populated
/// stack. So the stack is checked first and the remaining failure gets its own
/// code.
@JS public func editUndo(handle: Int) -> EditOutcome {
    let scoreHandle = Int64(handle)
    guard let session = session(for: scoreHandle) else {
        return bridgeRefusal(code: "bridge.noSession", operation: "editUndo", message: "no edit session is open")
    }
    guard session.canUndo else {
        return editRefusal(EditRefusal(operation: "editUndo", reason: .nothingToUndo))
    }
    guard session.undo() else {
        return bridgeRefusal(
            code: "bridge.undoFailed",
            operation: "editUndo",
            message: "the inverse command on the undo stack could not be applied",
        )
    }
    guard publish(session.score, to: scoreHandle) else {
        return bridgeRefusal(code: "bridge.publishFailed", operation: "editUndo", message: "score handle is gone")
    }
    return acceptedOutcome()
}

/// Android: `nativeEditRedo`, but returns the outcome channel so an empty stack
/// carries `edit.nothingToRedo`. Splits the two failure reasons for the same
/// reason `editUndo` does.
@JS public func editRedo(handle: Int) -> EditOutcome {
    let scoreHandle = Int64(handle)
    guard let session = session(for: scoreHandle) else {
        return bridgeRefusal(code: "bridge.noSession", operation: "editRedo", message: "no edit session is open")
    }
    guard session.canRedo else {
        return editRefusal(EditRefusal(operation: "editRedo", reason: .nothingToRedo))
    }
    guard session.redo() else {
        return bridgeRefusal(
            code: "bridge.redoFailed",
            operation: "editRedo",
            message: "the command on the redo stack could not be reapplied",
        )
    }
    guard publish(session.score, to: scoreHandle) else {
        return bridgeRefusal(code: "bridge.publishFailed", operation: "editRedo", message: "score handle is gone")
    }
    return acceptedOutcome()
}

/// No Android counterpart: Kotlin reads its authoritative session directly.
/// Unknown handles and handles without a session return `active == false`.
@JS public func editSessionState(handle: Int) -> EditSessionState {
    let scoreHandle = Int64(handle)
    guard let session = session(for: scoreHandle) else {
        return inactiveEditSessionState()
    }
    guard let affected = session.lastAffectedLocation else {
        return EditSessionState(
            active: true,
            canUndo: session.canUndo,
            canRedo: session.canRedo,
            hasLastAffected: false,
            lastAffectedPartIndex: -1,
            lastAffectedStaffIndexInPart: -1,
            lastAffectedMeasureIndex: -1,
            lastAffectedVoiceIndex: -1,
            lastAffectedElementIndex: -1,
        )
    }
    return EditSessionState(
        active: true,
        canUndo: session.canUndo,
        canRedo: session.canRedo,
        hasLastAffected: true,
        lastAffectedPartIndex: affected.staff.partIndex,
        lastAffectedStaffIndexInPart: affected.staff.staffIndexInPart,
        lastAffectedMeasureIndex: affected.measureIndex,
        lastAffectedVoiceIndex: affected.voiceIndex,
        lastAffectedElementIndex: affected.elementIndex,
    )
}

func releaseEditSession(handle: Int64) {
    withEditSessions { editSessions[handle] = nil }
}

func session(for scoreHandle: Int64) -> ScoreEditSession? {
    withEditSessions { editSessions[scoreHandle] }
}

func acceptedOutcome() -> EditOutcome {
    EditOutcome(accepted: true, code: "", operation: "", message: "")
}

func editRefusal(_ refusal: EditRefusal) -> EditOutcome {
    EditOutcome(
        accepted: false,
        code: refusal.code,
        operation: refusal.operation,
        message: refusal.developerDescription,
    )
}

func bridgeRefusal(code: String, operation: String, message: String) -> EditOutcome {
    EditOutcome(accepted: false, code: code, operation: operation, message: message)
}

/// Writes the edited score back into the existing handle and invalidates every
/// cache derived from the old score.
///
/// The `PlaybackClockCache.release` call is the wasm-only difference from
/// Android's publish path. Android rebuilds its playback timeline on every
/// query, but wasm caches a `PlaybackClock` per handle; without releasing it,
/// `cursorRectAtPlayerSeconds`, `playerSecondsForMeasure` and
/// `playbackSummary` would keep answering from the pre-edit timeline after a
/// successful edit, silently desynchronizing playback from notation.
///
/// Returns `false` when the score handle no longer exists. In that case the
/// caches are left untouched because there is no live handle to invalidate.
@discardableResult
func publish(_ score: Score, to scoreHandle: Int64) -> Bool {
    guard scoreTable.replace(scoreHandle, with: score) else { return false }
    LayoutDocumentCache.release(scoreHandle)
    PlaybackClockCache.release(scoreHandle)
    return true
}

private func inactiveEditSessionState() -> EditSessionState {
    EditSessionState(
        active: false,
        canUndo: false,
        canRedo: false,
        hasLastAffected: false,
        lastAffectedPartIndex: -1,
        lastAffectedStaffIndexInPart: -1,
        lastAffectedMeasureIndex: -1,
        lastAffectedVoiceIndex: -1,
        lastAffectedElementIndex: -1,
    )
}
