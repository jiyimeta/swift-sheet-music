import SheetMusicCore
import SheetMusicEditWire
import SheetMusicFoundation

struct ScalarIntentError: Error {
    let message: String
}

func scalarVoiceElementID(
    partIndex: Int,
    staffIndexInPart: Int,
    measureIndex: Int,
    voiceIndex: Int,
    elementIndex: Int,
) -> VoiceElementID {
    VoiceElementID(
        staff: StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndexInPart),
        measureIndex: measureIndex,
        voiceIndex: voiceIndex,
        elementIndex: elementIndex,
    )
}

func scalarRestID(
    partIndex: Int,
    staffIndexInPart: Int,
    measureIndex: Int,
    voiceIndex: Int,
    elementIndex: Int,
) -> RestID {
    RestID(
        staff: StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndexInPart),
        measureIndex: measureIndex,
        voiceIndex: voiceIndex,
        elementIndex: elementIndex,
    )
}

func scalarNoteID(
    partIndex: Int,
    staffIndexInPart: Int,
    measureIndex: Int,
    voiceIndex: Int,
    elementIndex: Int,
    noteIndexInChord: Int,
) -> NoteID {
    NoteID(
        staff: StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndexInPart),
        measureIndex: measureIndex,
        voiceIndex: voiceIndex,
        elementIndex: elementIndex,
        noteIndexInChord: noteIndexInChord,
    )
}

func parseOptionalDuration(kind: Int, numerator: Int, denominator: Int) throws -> NoteDuration? {
    guard kind != 0 else { return nil }
    return try parseRequiredDuration(kind: kind, numerator: numerator, denominator: denominator)
}

func parseRequiredDuration(kind: Int, numerator: Int, denominator: Int) throws -> NoteDuration {
    guard (1 ... 11).contains(kind) else {
        throw ScalarIntentError(message: "durationKind must be 1...11")
    }
    var wire = NoteDurationWire(from: .whole)
    wire.kind = UInt8(kind)
    wire.numerator = Int32(numerator)
    wire.denominator = Int32(denominator)
    do {
        return try wire.decoded()
    } catch {
        throw ScalarIntentError(message: "duration fraction is invalid")
    }
}

func parseChordDuration(kind: Int, numerator: Int, denominator: Int) throws -> NoteDuration {
    guard kind != 10 else {
        throw ScalarIntentError(message: "measure duration is rest-only")
    }
    return try parseRequiredDuration(kind: kind, numerator: numerator, denominator: denominator)
}

func parseWriteNoteDuration(kind: Int, numerator: Int, denominator: Int) throws -> NoteDuration? {
    guard kind != 10 else {
        throw ScalarIntentError(message: "measure duration is rest-only")
    }
    return try parseOptionalDuration(kind: kind, numerator: numerator, denominator: denominator)
}

func parseOptionalAccidental(_ rawValue: String) throws -> Accidental? {
    guard !rawValue.isEmpty else { return nil }
    guard let accidental = Accidental(rawValue: rawValue) else {
        throw ScalarIntentError(message: "accidental is not recognized")
    }
    return accidental
}

func parseOptionalIndex(hasValue: Int, value: Int, name: String) throws -> Int? {
    switch hasValue {
    case 0:
        return nil
    case 1:
        return value
    default:
        throw ScalarIntentError(message: "\(name) presence flag must be 0 or 1")
    }
}

func applyScalarEdit(
    handle: Int,
    operation: String,
    makeIntent: () throws -> EditIntent,
) -> EditOutcome {
    let scoreHandle = Int64(handle)
    guard let session = session(for: scoreHandle) else {
        return bridgeRefusal(code: "bridge.noSession", operation: operation, message: "no edit session is open")
    }
    let intent: EditIntent
    do {
        intent = try makeIntent()
    } catch let error as ScalarIntentError {
        return bridgeRefusal(code: "bridge.invalidArgument", operation: operation, message: error.message)
    } catch {
        return bridgeRefusal(
            code: "bridge.invalidArgument",
            operation: operation,
            message: "scalar edit arguments are invalid",
        )
    }
    guard session.apply(intent) else {
        return editRefusal(session.lastRefusal ?? EditRefusal(operation: operation, reason: .nothingToApply))
    }
    guard publish(session.score, to: scoreHandle) else {
        return bridgeRefusal(code: "bridge.publishFailed", operation: operation, message: "score handle is gone")
    }
    return acceptedOutcome()
}
