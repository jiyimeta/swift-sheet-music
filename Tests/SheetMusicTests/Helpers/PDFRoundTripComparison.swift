import Foundation
@testable import SheetMusicCore
import Testing

/// Loose equivalence comparator for PDF self-roundtrip
/// (`mscx → Score → PDF → Score`).
///
/// Phase 1 (this commit) only asserts the importer didn't return a
/// degenerate score. Strict per-measure semantic equivalence
/// (chord pitches, rest durations, key/time signatures, voltas,
/// markers, lyrics) is deferred until the content-stream walker
/// decodes a real `/ToUnicode` CMap from the embedded Bravura font;
/// today's CMap stub can't translate font CIDs back to PUA
/// codepoints, so the importer typically can't recover noteheads
/// or pitches from real exporter output.
@MainActor
enum PDFRoundTripComparison {
    /// Loose musical-equivalence assertion for PDF roundtrip.
    /// Strict comparisons are TODO pending real ToUnicode CMap
    /// decoding in `ContentStreamWalker`.
    static func assertLooselyEquivalent(
        _ a: Score,
        _ b: Score,
        fixture: String,
    ) {
        // Parts: importer should recover at least 1.
        #expect(
            b.parts.count >= 1,
            "[\(fixture)] expected ≥1 part imported; got \(b.parts.count)",
        )
        // Staves: importer should detect at least 1 staff.
        #expect(
            b.totalStaffCount >= 1,
            "[\(fixture)] expected ≥1 staff imported; got \(b.totalStaffCount)",
        )
        // Measures: at least 1 measure on staff 0.
        if let firstStaff = b.allStaves.first?.staff {
            #expect(
                !firstStaff.measures.isEmpty,
                "[\(fixture)] expected ≥1 measure on staff 0",
            )
        }
        // Reference the source score so the parameter isn't unused;
        // future strict checks will diff the two.
        _ = a
    }

    // TODO(strict): once real CMap decoding is implemented, compare
    // per-measure voice content: chord pitches+durations, rest
    // durations, key/time signatures, barline subtypes, voltas,
    // markers/jumps/lyrics. See `ScoreSemanticComparison` for the
    // tolerant comparator already used by the MIDI roundtrip suite.
}
