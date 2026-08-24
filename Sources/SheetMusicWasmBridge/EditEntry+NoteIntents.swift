import JavaScriptKit
import SheetMusicCore

@JS public func editInputNote(
    handle: Int,
    partIndex: Int,
    staffIndexInPart: Int,
    measureIndex: Int,
    voiceIndex: Int,
    elementIndex: Int,
    pitch: Int,
    tpc: Int,
    durationKind: Int,
    durationNumerator: Int,
    durationDenominator: Int,
) -> EditOutcome {
    applyScalarEdit(handle: handle, operation: "editInputNote") {
        try .inputNote(
            at: scalarRestID(
                partIndex: partIndex,
                staffIndexInPart: staffIndexInPart,
                measureIndex: measureIndex,
                voiceIndex: voiceIndex,
                elementIndex: elementIndex,
            ),
            pitch: pitch,
            tpc: tpc,
            duration: parseOptionalDuration(
                kind: durationKind,
                numerator: durationNumerator,
                denominator: durationDenominator,
            ),
        )
    }
}

@JS public func editWriteNote(
    handle: Int,
    partIndex: Int,
    staffIndexInPart: Int,
    measureIndex: Int,
    voiceIndex: Int,
    elementIndex: Int,
    pitch: Int,
    tpc: Int,
    durationKind: Int,
    durationNumerator: Int,
    durationDenominator: Int,
) -> EditOutcome {
    applyScalarEdit(handle: handle, operation: "editWriteNote") {
        try .writeNote(
            at: scalarVoiceElementID(
                partIndex: partIndex,
                staffIndexInPart: staffIndexInPart,
                measureIndex: measureIndex,
                voiceIndex: voiceIndex,
                elementIndex: elementIndex,
            ),
            pitch: pitch,
            tpc: tpc,
            duration: parseWriteNoteDuration(
                kind: durationKind,
                numerator: durationNumerator,
                denominator: durationDenominator,
            ),
        )
    }
}

@JS public func editSetNotePitch(
    handle: Int,
    partIndex: Int,
    staffIndexInPart: Int,
    measureIndex: Int,
    voiceIndex: Int,
    elementIndex: Int,
    noteIndexInChord: Int,
    pitch: Int,
    tpc: Int,
    accidental: String,
) -> EditOutcome {
    applyScalarEdit(handle: handle, operation: "editSetNotePitch") {
        try .setNotePitch(
            at: scalarNoteID(
                partIndex: partIndex,
                staffIndexInPart: staffIndexInPart,
                measureIndex: measureIndex,
                voiceIndex: voiceIndex,
                elementIndex: elementIndex,
                noteIndexInChord: noteIndexInChord,
            ),
            pitch: pitch,
            tpc: tpc,
            accidental: parseOptionalAccidental(accidental),
        )
    }
}

@JS public func editSetAccidental(
    handle: Int,
    partIndex: Int,
    staffIndexInPart: Int,
    measureIndex: Int,
    voiceIndex: Int,
    elementIndex: Int,
    noteIndexInChord: Int,
    accidental: String,
) -> EditOutcome {
    applyScalarEdit(handle: handle, operation: "editSetAccidental") {
        try .setAccidental(
            at: scalarNoteID(
                partIndex: partIndex,
                staffIndexInPart: staffIndexInPart,
                measureIndex: measureIndex,
                voiceIndex: voiceIndex,
                elementIndex: elementIndex,
                noteIndexInChord: noteIndexInChord,
            ),
            accidental: parseOptionalAccidental(accidental),
        )
    }
}

@JS public func editAddNoteToChord(
    handle: Int,
    partIndex: Int,
    staffIndexInPart: Int,
    measureIndex: Int,
    voiceIndex: Int,
    elementIndex: Int,
    pitch: Int,
    tpc: Int,
    accidental: String,
) -> EditOutcome {
    applyScalarEdit(handle: handle, operation: "editAddNoteToChord") {
        try .addNoteToChord(
            at: scalarVoiceElementID(
                partIndex: partIndex,
                staffIndexInPart: staffIndexInPart,
                measureIndex: measureIndex,
                voiceIndex: voiceIndex,
                elementIndex: elementIndex,
            ),
            pitch: pitch,
            tpc: tpc,
            accidental: parseOptionalAccidental(accidental),
        )
    }
}

@JS public func editRemoveNoteFromChord(
    handle: Int,
    partIndex: Int,
    staffIndexInPart: Int,
    measureIndex: Int,
    voiceIndex: Int,
    elementIndex: Int,
    noteIndexInChord: Int,
) -> EditOutcome {
    applyScalarEdit(handle: handle, operation: "editRemoveNoteFromChord") {
        .removeNoteFromChord(at: scalarNoteID(
            partIndex: partIndex,
            staffIndexInPart: staffIndexInPart,
            measureIndex: measureIndex,
            voiceIndex: voiceIndex,
            elementIndex: elementIndex,
            noteIndexInChord: noteIndexInChord,
        ))
    }
}

@JS public func editSetTie(
    handle: Int,
    fromPartIndex: Int,
    fromStaffIndexInPart: Int,
    fromMeasureIndex: Int,
    fromVoiceIndex: Int,
    fromElementIndex: Int,
    fromNoteIndexInChord: Int,
    toPartIndex: Int,
    toStaffIndexInPart: Int,
    toMeasureIndex: Int,
    toVoiceIndex: Int,
    toElementIndex: Int,
    toNoteIndexInChord: Int,
    hasSourceTieForward: Int,
    sourceTieForward: Int,
    hasTargetTieBack: Int,
    targetTieBack: Int,
) -> EditOutcome {
    applyScalarEdit(handle: handle, operation: "editSetTie") {
        try .setTie(
            from: scalarNoteID(
                partIndex: fromPartIndex,
                staffIndexInPart: fromStaffIndexInPart,
                measureIndex: fromMeasureIndex,
                voiceIndex: fromVoiceIndex,
                elementIndex: fromElementIndex,
                noteIndexInChord: fromNoteIndexInChord,
            ),
            to: scalarNoteID(
                partIndex: toPartIndex,
                staffIndexInPart: toStaffIndexInPart,
                measureIndex: toMeasureIndex,
                voiceIndex: toVoiceIndex,
                elementIndex: toElementIndex,
                noteIndexInChord: toNoteIndexInChord,
            ),
            sourceTieForward: parseOptionalIndex(
                hasValue: hasSourceTieForward,
                value: sourceTieForward,
                name: "sourceTieForward",
            ),
            targetTieBack: parseOptionalIndex(
                hasValue: hasTargetTieBack,
                value: targetTieBack,
                name: "targetTieBack",
            ),
        )
    }
}
