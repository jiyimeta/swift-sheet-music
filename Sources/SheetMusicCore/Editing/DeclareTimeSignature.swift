import SheetMusicFoundation

/// Writes a meter into `measureIndex`'s leading signature run on every staff WITHOUT re-barring — what the planner
/// answers a `.setTimeSignature` with when the bar already inherits that meter
/// (`ScoreEditSession+SignaturePlanning`).
///
/// The bar's length is the meter in force already, so every barline is where the declaration would put it and
/// nothing outside the run changes. What changes is what the bar DECLARES: it now bounds the span of a change written
/// before it, which re-bars only up to the next declared meter (`TimeSignatureRegion.nextExplicitChange`). Re-barring
/// to the same meter instead would rebuild every bar up to that next declaration for no difference on the page.
///
/// ## The inverse
///
/// The pre-image of every staff's voice-0 leading run (`RestoreSignaturePrefixes`), the idiom `SetKeySignature` uses
/// for the same reason: the run may already hold a clef or a key, and only the pre-image says where the meter went.
struct DeclareTimeSignature: EditCommand {
    let measureIndex: Int
    let numerator: Int
    let denominator: Int
    let symbol: TimeSignatureSymbol

    var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: measureIndex, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard measureIndex >= 0, measureIndex < MeasureStructure.measureCount(of: score), !score.parts.isEmpty
        else { throw Self.refused(.targetNotFound(affectedLocation)) }
        try SetTimeSignature.validate(numerator: numerator, denominator: denominator, symbol: symbol)

        let previous = SignaturePrefixes.captured(from: score, at: measureIndex)
        let signature = TimeSignature(numerator: numerator, denominator: denominator, symbol: symbol)
        for partIndex in score.parts.indices {
            for staffIndex in score.parts[partIndex].staves.indices {
                let address = StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex)
                SignaturePrefixes.mutateVoiceZero(of: &score, at: address, measureIndex: measureIndex) { voice in
                    Self.declare(signature, in: &voice, ids: &ids)
                }
            }
        }
        return RestoreSignaturePrefixes(prefixes: previous, measureIndex: measureIndex)
    }

    /// Inserts `signature` at the end of `voice`'s leading run — the canonical clef → key → time position — or, on a
    /// staff whose run already carries a meter (one the canonical staff does not, which a well-formed score never
    /// has), rewrites that one in place rather than writing a second.
    private static func declare(_ signature: TimeSignature, in voice: inout Voice, ids: inout EIDAllocator) {
        let prefix = MeasureStructure.leadingSignaturePrefix(of: voice)
        if let existing = prefix.firstIndex(where: { if case .timeSignature = $0 { true } else { false } }),
           case var .timeSignature(current) = voice.elements[existing]
        {
            current.numerator = signature.numerator
            current.denominator = signature.denominator
            current.symbol = signature.symbol
            voice.elements.updateValue(at: existing) { $0 = .timeSignature(current) }
            return
        }
        voice.elements.insert(.timeSignature(signature), at: prefix.count, id: ids.next())
    }
}

/// Puts one bar's leading signature runs back exactly as captured — the inverse `DeclareTimeSignature` returns, and
/// its own inverse, built from a pre-image captured before the splice so undo and redo cycle through one code path.
struct RestoreSignaturePrefixes: EditCommand {
    let prefixes: [[SignaturePrefixSnapshot]]
    let measureIndex: Int

    var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: measureIndex, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    func apply(to score: inout Score, ids _: inout EIDAllocator) throws -> any EditCommand {
        guard measureIndex >= 0, measureIndex < MeasureStructure.measureCount(of: score), !score.parts.isEmpty
        else { throw Self.refused(.targetNotFound(affectedLocation)) }
        let previous = SignaturePrefixes.captured(from: score, at: measureIndex)
        SignaturePrefixes.splice(prefixes, into: &score, at: measureIndex)
        return RestoreSignaturePrefixes(prefixes: previous, measureIndex: measureIndex)
    }
}
