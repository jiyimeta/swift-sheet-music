import SheetMusicCore
@testable import SheetMusicWasmBridge

extension EditScalarEntryTests {
    static func inputNoteCase() -> ScalarCase {
        ScalarCase(
            score: { fourQuarterRests() },
            intent: .inputNote(
                at: RestID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1),
                pitch: 60,
                tpc: 14,
                duration: .half,
            ),
        ) {
            editInputNote(
                handle: $0,
                partIndex: 0,
                staffIndexInPart: 0,
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 1,
                pitch: 60,
                tpc: 14,
                durationKind: 2,
                durationNumerator: 0,
                durationDenominator: 0,
            )
        }
    }

    static func setRestDurationCase() -> ScalarCase {
        ScalarCase(
            score: { fourQuarterRests() },
            intent: .setRestDuration(at: slot1, duration: .fraction(Fraction(numerator: 1, denominator: 8))),
        ) {
            editSetRestDuration(
                handle: $0,
                partIndex: 0,
                staffIndexInPart: 0,
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 1,
                durationKind: 11,
                durationNumerator: 1,
                durationDenominator: 8,
            )
        }
    }

    static func setChordDurationCase() -> ScalarCase {
        ScalarCase(score: { chordAtIndex1() }, intent: .setChordDuration(at: slot1, duration: .eighth)) {
            editSetChordDuration(
                handle: $0,
                partIndex: 0,
                staffIndexInPart: 0,
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 1,
                durationKind: 4,
                durationNumerator: 0,
                durationDenominator: 0,
            )
        }
    }

    static func deleteCase() -> ScalarCase {
        ScalarCase(score: { chordAtIndex1() }, intent: .delete(at: slot1)) {
            editDelete(
                handle: $0,
                partIndex: 0,
                staffIndexInPart: 0,
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 1,
            )
        }
    }

    static func setNotePitchCase() -> ScalarCase {
        ScalarCase(score: { chordAtIndex1() }, intent: .setNotePitch(
            at: note0,
            pitch: 62,
            tpc: 16,
            accidental: .natural,
        )) {
            editSetNotePitch(
                handle: $0,
                partIndex: 0,
                staffIndexInPart: 0,
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 1,
                noteIndexInChord: 0,
                pitch: 62,
                tpc: 16,
                accidental: Accidental.natural.rawValue,
            )
        }
    }

    static func setAccidentalCase() -> ScalarCase {
        ScalarCase(score: { chordAtIndex1() }, intent: .setAccidental(at: note0, accidental: .sharp)) {
            editSetAccidental(
                handle: $0,
                partIndex: 0,
                staffIndexInPart: 0,
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 1,
                noteIndexInChord: 0,
                accidental: Accidental.sharp.rawValue,
            )
        }
    }

    static func addNoteToChordCase() -> ScalarCase {
        ScalarCase(score: { chordAtIndex1() }, intent: .addNoteToChord(
            at: slot1,
            pitch: 67,
            tpc: 15,
            accidental: .flat,
        )) {
            editAddNoteToChord(
                handle: $0,
                partIndex: 0,
                staffIndexInPart: 0,
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 1,
                pitch: 67,
                tpc: 15,
                accidental: Accidental.flat.rawValue,
            )
        }
    }

    static func removeNoteFromChordCase() -> ScalarCase {
        ScalarCase(score: { twoNoteChordAtIndex1() }, intent: .removeNoteFromChord(at: note1)) {
            editRemoveNoteFromChord(
                handle: $0,
                partIndex: 0,
                staffIndexInPart: 0,
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 1,
                noteIndexInChord: 1,
            )
        }
    }

    static func setTieCase() -> ScalarCase {
        ScalarCase(
            score: { twoConsecutiveC4Chords() },
            intent: .setTie(from: note0, to: note2, sourceTieForward: 1, targetTieBack: 1),
        ) {
            editSetTie(
                handle: $0,
                fromPartIndex: 0,
                fromStaffIndexInPart: 0,
                fromMeasureIndex: 0,
                fromVoiceIndex: 0,
                fromElementIndex: 1,
                fromNoteIndexInChord: 0,
                toPartIndex: 0,
                toStaffIndexInPart: 0,
                toMeasureIndex: 0,
                toVoiceIndex: 0,
                toElementIndex: 2,
                toNoteIndexInChord: 0,
                hasSourceTieForward: 1,
                sourceTieForward: 1,
                hasTargetTieBack: 1,
                targetTieBack: 1,
            )
        }
    }

    static func createTupletCase() -> ScalarCase {
        ScalarCase(score: { fourQuarterRests() }, intent: .createTuplet(at: slot1, actualNotes: 3, normalNotes: 2)) {
            editCreateTuplet(
                handle: $0,
                partIndex: 0,
                staffIndexInPart: 0,
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 1,
                actualNotes: 3,
                normalNotes: 2,
            )
        }
    }

    static func removeTupletCase() -> ScalarCase {
        ScalarCase(score: { try tripletScore() }, intent: .removeTuplet(at: slot1)) {
            editRemoveTuplet(
                handle: $0,
                partIndex: 0,
                staffIndexInPart: 0,
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 1,
            )
        }
    }

    static func writeNoteCase() -> ScalarCase {
        ScalarCase(score: { chordAtIndex1() }, intent: .writeNote(
            at: slot1,
            pitch: 65,
            tpc: 13,
            duration: .sixteenth,
        )) {
            editWriteNote(
                handle: $0,
                partIndex: 0,
                staffIndexInPart: 0,
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 1,
                pitch: 65,
                tpc: 13,
                durationKind: 5,
                durationNumerator: 0,
                durationDenominator: 0,
            )
        }
    }

    static func writeRestCase() -> ScalarCase {
        ScalarCase(score: { chordAtIndex1() }, intent: .writeRest(at: slot1, duration: .half)) {
            editWriteRest(
                handle: $0,
                partIndex: 0,
                staffIndexInPart: 0,
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 1,
                durationKind: 2,
                durationNumerator: 0,
                durationDenominator: 0,
            )
        }
    }
}
