#if !os(Android)
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF

    /// Stable string names for `SMuFLSemantic` cases — the label-format
    /// class vocabulary (spec §7.1). The DETECTOR vocabulary and its
    /// class ↔ semantic table now live in `OMRGlyphVocabulary`
    /// (`SheetMusicPDF`, reached here via `@testable import`); this type
    /// keeps only the `className(for:)` direction, which the label-export
    /// pipeline (a Tests-only concern) still needs.
    ///
    /// `className(for:)` is TOTAL: every `SMuFLSemantic` value maps to a
    /// name. `OMRGlyphVocabulary.semantic(forClassName:)` round-trips
    /// every name that `className(for:)` can produce, with exactly one
    /// deliberate exception: `restOther`, the shared fallback for
    /// `.rest(.fraction)` and `.rest(.measure)`. That name discards the
    /// duration's parameters, so the reverse direction cannot reconstruct
    /// which rest it was and `semantic(forClassName: "restOther")` returns
    /// `nil` on purpose — do not turn this into a fabricated duration.
    /// Gate P0-G1 (Task 6) needs the oracle replay to compare `Score`
    /// values exactly; a silent wrong-but-plausible duration would
    /// corrupt that gate, while `nil` fails loudly as intended.
    enum OMRLabelClassNames {
        /// Forwards to the table that now lives in `SheetMusicPDF`. Kept as
        /// a name so this file's many callers need no churn.
        static var detectorVocabulary: [String] {
            OMRGlyphVocabulary.detectorVocabulary
        }

        private static let nameBySemantic: [SMuFLSemantic: String] =
            Dictionary(uniqueKeysWithValues: OMRGlyphVocabulary.detectorTable.map { ($0.semantic, $0.className) })

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
                // Unreachable while OMRGlyphVocabulary.detectorTable covers
                // every remaining case. A new SMuFLSemantic case added
                // upstream lands here — and NO test catches that
                // statically: `roundTripsEveryDetectorClass` iterates
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
    }
#endif
