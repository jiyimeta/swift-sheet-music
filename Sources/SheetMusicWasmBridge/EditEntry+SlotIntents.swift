import JavaScriptKit
import SheetMusicCore

@JS public func editWriteRest(
    handle: Int,
    partIndex: Int,
    staffIndexInPart: Int,
    measureIndex: Int,
    voiceIndex: Int,
    elementIndex: Int,
    durationKind: Int,
    durationNumerator: Int,
    durationDenominator: Int,
) -> EditOutcome {
    applyScalarEdit(handle: handle, operation: "editWriteRest") {
        try .writeRest(
            at: scalarVoiceElementID(
                partIndex: partIndex,
                staffIndexInPart: staffIndexInPart,
                measureIndex: measureIndex,
                voiceIndex: voiceIndex,
                elementIndex: elementIndex,
            ),
            duration: parseRequiredDuration(
                kind: durationKind,
                numerator: durationNumerator,
                denominator: durationDenominator,
            ),
        )
    }
}

@JS public func editSetRestDuration(
    handle: Int,
    partIndex: Int,
    staffIndexInPart: Int,
    measureIndex: Int,
    voiceIndex: Int,
    elementIndex: Int,
    durationKind: Int,
    durationNumerator: Int,
    durationDenominator: Int,
) -> EditOutcome {
    applyScalarEdit(handle: handle, operation: "editSetRestDuration") {
        try .setRestDuration(
            at: scalarVoiceElementID(
                partIndex: partIndex,
                staffIndexInPart: staffIndexInPart,
                measureIndex: measureIndex,
                voiceIndex: voiceIndex,
                elementIndex: elementIndex,
            ),
            duration: parseRequiredDuration(
                kind: durationKind,
                numerator: durationNumerator,
                denominator: durationDenominator,
            ),
        )
    }
}

@JS public func editSetChordDuration(
    handle: Int,
    partIndex: Int,
    staffIndexInPart: Int,
    measureIndex: Int,
    voiceIndex: Int,
    elementIndex: Int,
    durationKind: Int,
    durationNumerator: Int,
    durationDenominator: Int,
) -> EditOutcome {
    applyScalarEdit(handle: handle, operation: "editSetChordDuration") {
        try .setChordDuration(
            at: scalarVoiceElementID(
                partIndex: partIndex,
                staffIndexInPart: staffIndexInPart,
                measureIndex: measureIndex,
                voiceIndex: voiceIndex,
                elementIndex: elementIndex,
            ),
            duration: parseChordDuration(
                kind: durationKind,
                numerator: durationNumerator,
                denominator: durationDenominator,
            ),
        )
    }
}

@JS public func editDelete(
    handle: Int,
    partIndex: Int,
    staffIndexInPart: Int,
    measureIndex: Int,
    voiceIndex: Int,
    elementIndex: Int,
) -> EditOutcome {
    applyScalarEdit(handle: handle, operation: "editDelete") {
        .delete(at: scalarVoiceElementID(
            partIndex: partIndex,
            staffIndexInPart: staffIndexInPart,
            measureIndex: measureIndex,
            voiceIndex: voiceIndex,
            elementIndex: elementIndex,
        ))
    }
}

@JS public func editCreateTuplet(
    handle: Int,
    partIndex: Int,
    staffIndexInPart: Int,
    measureIndex: Int,
    voiceIndex: Int,
    elementIndex: Int,
    actualNotes: Int,
    normalNotes: Int,
) -> EditOutcome {
    applyScalarEdit(handle: handle, operation: "editCreateTuplet") {
        guard actualNotes > 1, normalNotes > 0 else {
            throw ScalarIntentError(message: "tuplet ratio must have actualNotes > 1 and normalNotes > 0")
        }
        return .createTuplet(
            at: scalarVoiceElementID(
                partIndex: partIndex,
                staffIndexInPart: staffIndexInPart,
                measureIndex: measureIndex,
                voiceIndex: voiceIndex,
                elementIndex: elementIndex,
            ),
            actualNotes: actualNotes,
            normalNotes: normalNotes,
        )
    }
}

@JS public func editRemoveTuplet(
    handle: Int,
    partIndex: Int,
    staffIndexInPart: Int,
    measureIndex: Int,
    voiceIndex: Int,
    elementIndex: Int,
) -> EditOutcome {
    applyScalarEdit(handle: handle, operation: "editRemoveTuplet") {
        .removeTuplet(at: scalarVoiceElementID(
            partIndex: partIndex,
            staffIndexInPart: staffIndexInPart,
            measureIndex: measureIndex,
            voiceIndex: voiceIndex,
            elementIndex: elementIndex,
        ))
    }
}
