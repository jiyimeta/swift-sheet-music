import SheetMusicFoundation

/// The stable dotted identifier each refusal reason carries — what a bridge sends and a host's localization keys
/// off.
///
/// Split out of `EditRefusal.swift` rather than added to it: this switch grows by one line for every reason the
/// engine learns to state, and what a reader comes to that file for is the declaration of the reasons themselves.
extension EditRefusal {
    /// Stable dotted identifier under the `edit.` namespace.
    public var code: String {
        switch reason {
        case .targetNotFound:
            "edit.targetNotFound"
        case .noteNotFound:
            "edit.noteNotFound"
        case .staffNotFound:
            "edit.staffNotFound"
        case .wrongElementKind:
            "edit.wrongElementKind"
        case .insufficientRoom:
            "edit.insufficientRoom"
        case .blockedByUntimedElement:
            "edit.blockedByUntimedElement"
        case .insideTuplet:
            "edit.insideTuplet"
        case .indivisibleTuplet:
            "edit.indivisibleTuplet"
        case .invalidTupletRatio:
            "edit.invalidTupletRatio"
        case .tupletOverlap:
            "edit.tupletOverlap"
        case .duplicatePitch:
            "edit.duplicatePitch"
        case .emptyPayload:
            "edit.emptyPayload"
        case .unreadablePayload:
            "edit.unreadablePayload"
        case .noPayloadReader:
            "edit.noPayloadReader"
        case .nothingToUndo:
            "edit.nothingToUndo"
        case .nothingToRedo:
            "edit.nothingToRedo"
        case .compositeTooDeep:
            "edit.compositeTooDeep"
        case .nothingToApply:
            "edit.nothingToApply"
        case .cannotDeleteOnlyMeasure:
            "edit.cannotDeleteOnlyMeasure"
        case .cannotRemoveLastPart:
            "edit.cannotRemoveLastPart"
        case .cannotRemoveInitialSignature:
            "edit.cannotRemoveInitialSignature"
        case .rebarWouldSplitTuplet:
            "edit.rebarWouldSplitTuplet"
        case .rebarWouldDisplaceBarlineMarker:
            "edit.rebarWouldDisplaceBarlineMarker"
        case .invalidTimeSignatureValue:
            "edit.invalidTimeSignatureValue"
        case .timeSignatureSymbolMismatch:
            "edit.timeSignatureSymbolMismatch"
        case .emptyRehearsalMarkText:
            "edit.emptyRehearsalMarkText"
        case .voiceAlreadyExists:
            "edit.voiceAlreadyExists"
        case .invalidRepeatCount:
            "edit.invalidRepeatCount"
        case .invalidMeasureRepeatSpan:
            "edit.invalidMeasureRepeatSpan"
        case .measureRepeatSpanNotEmpty:
            "edit.measureRepeatSpanNotEmpty"
        case .voiceMismatch:
            "edit.voiceMismatch"
        case .destinationNotFree:
            "edit.destinationNotFree"
        case .invalidTransposition:
            "edit.invalidTransposition"
        case .invalidInterval:
            "edit.invalidInterval"
        case .emptyStaffText:
            "edit.emptyStaffText"
        case .emptyChordSymbol:
            "edit.emptyChordSymbol"
        case .occupiedLyricVerse:
            "edit.occupiedLyricVerse"
        case .invalidVerse:
            "edit.invalidVerse"
        case .emptyLyricText:
            "edit.emptyLyricText"
        case .noNextChord:
            "edit.noNextChord"
        case .chordTooSmall:
            "edit.chordTooSmall"
        case .notDottable:
            "edit.notDottable"
        case .notBeamed:
            "edit.notBeamed"
        case .duplicateSpanner:
            "edit.duplicateSpanner"
        case .noSpannerAtLocation:
            "edit.noSpannerAtLocation"
        case .unexpected:
            "edit.unexpected"
        case .noTieBetween:
            "edit.noTieBetween"
        }
    }
}
