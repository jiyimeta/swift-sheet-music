import Foundation
import SheetMusicCore

extension PDFImporter {
    /// Map a SMuFL codepoint to its semantic. Unrecognized codepoints
    /// → `.unknown(codepoint)` so callers can emit a diagnostic.
    static func smuflSemantic(codepoint cp: UInt32) -> SMuFLSemantic {
        switch cp {
        case 0xE003: return .staff5Lines
        case 0xE043: return .repeatBarlineDots
        case 0xE047: return .segno
        case 0xE048: return .coda
        case 0xE050: return .clefG
        case 0xE052: return .clefG8vb // gClef8vb — vocal tenor clef
        case 0xE05C: return .clefC
        case 0xE062: return .clefF
        case 0xE069: return .clefPercussion
        case 0xE080 ... 0xE089: return .timeSignatureDigit(Int(cp - 0xE080))
        case 0xE08A: return .timeSignatureCommon
        case 0xE08B: return .timeSignatureCutTime
        case 0xE0A1: return .noteheadDoubleWhole
        case 0xE0A2: return .noteheadWhole
        case 0xE0A3: return .noteheadHalf
        case 0xE0A4: return .noteheadBlack
        case 0xE1E7: return .augmentationDot
        case 0xE240: return .flag8thUp
        case 0xE241: return .flag8thDown
        case 0xE242: return .flag16thUp
        case 0xE243: return .flag16thDown
        case 0xE244: return .flag32ndUp
        case 0xE245: return .flag32ndDown
        case 0xE246: return .flag64thUp
        case 0xE247: return .flag64thDown
        case 0xE260: return .accidentalFlat
        case 0xE261: return .accidentalNatural
        case 0xE262: return .accidentalSharp
        case 0xE263: return .accidentalDoubleSharp
        case 0xE264: return .accidentalDoubleFlat
        // Rests — only the durations supported by NoteDuration:
        case 0xE4E3: return .rest(.whole)
        case 0xE4E4: return .rest(.half)
        case 0xE4E5: return .rest(.quarter)
        case 0xE4E6: return .rest(.eighth)
        case 0xE4E7: return .rest(.sixteenth)
        case 0xE4E8: return .rest(.thirtySecond)
        case 0xE4E9: return .rest(.sixtyFourth)
        case 0xE4C0: return .fermata
        default:
            return .unknown(cp)
        }
    }
}
