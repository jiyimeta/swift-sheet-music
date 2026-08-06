#if !os(Android)
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF

    /// Stable string names for `SMuFLSemantic` cases — the label-format
    /// class vocabulary (spec §7.1). The DETECTOR vocabulary is the 64
    /// concrete classes below; `stem` / `staff5Lines` / `unknownXXXX` are
    /// also representable but excluded from the detector vocabulary.
    ///
    /// `className(for:)` is TOTAL: every `SMuFLSemantic` value maps to a
    /// name. `semantic(forClassName:)` round-trips every name that
    /// `className(for:)` can produce, with exactly one deliberate
    /// exception: `restOther`, the shared fallback for `.rest(.fraction)`
    /// and `.rest(.measure)`. That name discards the duration's
    /// parameters, so the reverse direction cannot reconstruct which rest
    /// it was and `semantic(forClassName: "restOther")` returns `nil` on
    /// purpose — do not turn this into a fabricated duration. Gate P0-G1
    /// (Task 6) needs the oracle replay to compare `Score` values
    /// exactly; a silent wrong-but-plausible duration would corrupt that
    /// gate, while `nil` fails loudly as intended.
    ///
    /// ORDER IS FROZEN: `Training/generate/vocabulary.py` mirrors this
    /// list 1:1 and COCO category ids are positions in it. Append-only.
    enum OMRLabelClassNames {
        /// (className, semantic) — one row per detector class.
        static let detectorTable: [(className: String, semantic: SMuFLSemantic)] = [
            ("brace", .brace),
            ("noteheadDoubleWhole", .noteheadDoubleWhole),
            ("noteheadWhole", .noteheadWhole),
            ("noteheadHalf", .noteheadHalf),
            ("noteheadBlack", .noteheadBlack),
            ("noteheadXWhole", .noteheadXWhole),
            ("noteheadXHalf", .noteheadXHalf),
            ("noteheadXBlack", .noteheadXBlack),
            ("flag8thUp", .flag8thUp),
            ("flag8thDown", .flag8thDown),
            ("flag16thUp", .flag16thUp),
            ("flag16thDown", .flag16thDown),
            ("flag32ndUp", .flag32ndUp),
            ("flag32ndDown", .flag32ndDown),
            ("flag64thUp", .flag64thUp),
            ("flag64thDown", .flag64thDown),
            ("augmentationDot", .augmentationDot),
            ("restWhole", .rest(.whole)),
            ("restHalf", .rest(.half)),
            ("restQuarter", .rest(.quarter)),
            ("rest8th", .rest(.eighth)),
            ("rest16th", .rest(.sixteenth)),
            ("rest32nd", .rest(.thirtySecond)),
            ("rest64th", .rest(.sixtyFourth)),
            ("clefG", .clefG),
            ("clefG8va", .clefG8va),
            ("clefG8vb", .clefG8vb),
            ("clefG15ma", .clefG15ma),
            ("clefG15mb", .clefG15mb),
            ("clefF", .clefF),
            ("clefF8va", .clefF8va),
            ("clefF8vb", .clefF8vb),
            ("clefF15ma", .clefF15ma),
            ("clefF15mb", .clefF15mb),
            ("clefC", .clefC),
            ("clefPercussion", .clefPercussion),
            ("accidentalSharp", .accidentalSharp),
            ("accidentalFlat", .accidentalFlat),
            ("accidentalNatural", .accidentalNatural),
            ("accidentalDoubleSharp", .accidentalDoubleSharp),
            ("accidentalDoubleFlat", .accidentalDoubleFlat),
            ("timeSig0", .timeSignatureDigit(0)),
            ("timeSig1", .timeSignatureDigit(1)),
            ("timeSig2", .timeSignatureDigit(2)),
            ("timeSig3", .timeSignatureDigit(3)),
            ("timeSig4", .timeSignatureDigit(4)),
            ("timeSig5", .timeSignatureDigit(5)),
            ("timeSig6", .timeSignatureDigit(6)),
            ("timeSig7", .timeSignatureDigit(7)),
            ("timeSig8", .timeSignatureDigit(8)),
            ("timeSig9", .timeSignatureDigit(9)),
            ("timeSigCommon", .timeSignatureCommon),
            ("timeSigCutTime", .timeSignatureCutTime),
            ("repeatBarlineDots", .repeatBarlineDots),
            ("segno", .segno),
            ("coda", .coda),
            ("dalSegno", .dalSegno),
            ("daCapo", .daCapo),
            ("fine", .fine),
            ("toCoda", .toCoda),
            ("fermata", .fermata),
            ("dynamic", .dynamic),
            ("articulation", .articulation),
            ("ornament", .ornament),
        ]

        static let detectorVocabulary: [String] = detectorTable.map(\.className)

        private static let nameBySemantic: [SMuFLSemantic: String] =
            Dictionary(uniqueKeysWithValues: detectorTable.map { ($0.semantic, $0.className) })
        private static let semanticByName: [String: SMuFLSemantic] =
            Dictionary(uniqueKeysWithValues: detectorTable.map { ($0.className, $0.semantic) })

        /// Total: every `SMuFLSemantic` value has a name. Non-detector
        /// cases get reserved names so a label file can carry ANY walked
        /// glyph. `restOther` is the one name that intentionally does NOT
        /// round-trip back through `semantic(forClassName:)` — see the
        /// type doc comment.
        static func className(for semantic: SMuFLSemantic) -> String {
            if let name = nameBySemantic[semantic] { return name }
            switch semantic {
            case .stem: return "stem"
            case .staff5Lines: return "staff5Lines"
            case .rest(.oneTwentyEighth): return "rest128th"
            case .rest(.twoFiftySixth): return "rest256th"
            // .fraction / .measure — the duration parameters are not
            // recoverable from this name; semantic(forClassName:) returns
            // nil for "restOther" by design, not by omission.
            case .rest: return "restOther"
            case let .unknown(cp):
                return String(format: "unknown%04X", cp)
            default:
                // Unreachable while detectorTable covers every remaining
                // case. A new SMuFLSemantic case added upstream lands
                // here — and NO test catches that statically:
                // `roundTripsEveryDetectorClass` iterates
                // `detectorVocabulary` (this table's own class names),
                // so it is exhaustive over the vocabulary, never over
                // `SMuFLSemantic`. The real detection channel is at
                // runtime, on a dataset: such a glyph is exported as
                // class `unknown0000`, which the label-export harness
                // counts into `tier1Missing` (see `OMRLabelExport`'s
                // `write`). A nonzero `tier1Missing` whose class is
                // exactly `unknown0000` means VOCABULARY DRIFT — come
                // back to this table, not to the classifier.
                return "unknown0000"
            }
        }

        /// `"restOther"` deliberately returns `nil` — it has no unique
        /// inverse, see the type doc comment.
        static func semantic(forClassName name: String) -> SMuFLSemantic? {
            if let s = semanticByName[name] { return s }
            switch name {
            case "stem": return .stem
            case "staff5Lines": return .staff5Lines
            case "rest128th": return .rest(.oneTwentyEighth)
            case "rest256th": return .rest(.twoFiftySixth)
            default: break
            }
            if name.hasPrefix("unknown"), name.count > "unknown".count,
               let cp = UInt32(name.dropFirst("unknown".count), radix: 16)
            {
                return .unknown(cp)
            }
            return nil
        }
    }
#endif
