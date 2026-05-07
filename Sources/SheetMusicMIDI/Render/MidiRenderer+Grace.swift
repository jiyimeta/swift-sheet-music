import Foundation
import SheetMusicCore

extension MidiRenderer {
    /// Default playback length of one grace note in ticks.
    /// Mirrors `CompatMidiRender::graceTickLen` — appoggiatura is
    /// proportional to the parent (`mainTicks/2`); the rest are
    /// constants in PPQ. `acciaccatura` is intentionally short
    /// (1/32 of a quarter) so it reads as a "crushed" ornament.
    static func playbackTicks(
        for grace: GraceChord, mainTicks: Int, division: Int
    ) -> Int {
        switch grace.graceType {
        case .acciaccatura: return division / 8 // 1/32 of a quarter
        case .appoggiatura: return max(0, mainTicks / 2)
        case .grace4: return division // 1/4 = quarter
        case .grace16: return division / 4
        case .grace32: return division / 8
        case .grace8after: return division / 2
        case .grace16after: return division / 4
        case .grace32after: return division / 8
        }
    }

    /// Time stolen from the *previous* chord's tail. Only
    /// acciaccaturas steal from the previous chord; every other
    /// before-grace steals from the parent chord's head.
    /// Mirrors `CompatMidiRender::renderGraceNotesBefore`.
    static func totalStealFromPrev(
        _ before: [GraceChord], division: Int
    ) -> Int {
        before.reduce(0) { acc, g in
            g.graceType == .acciaccatura
                ? acc + playbackTicks(for: g, mainTicks: 0, division: division)
                : acc
        }
    }

    /// Time stolen from the *parent* chord's head. Sum of every
    /// before-grace's playback length, EXCEPT acciaccatura (which
    /// steals from the previous chord). Capped at mainTicks/2 to
    /// keep the parent audible — MuseScore's
    /// `handleOverflowsForGrace` does a non-linear shrink; we do
    /// a single proportional clamp because it handles every realistic
    /// score and stays simple.
    static func totalStealFromMainHead(
        _ before: [GraceChord], mainTicks: Int, division: Int
    ) -> Int {
        let raw = before.reduce(0) { acc, g in
            g.graceType == .acciaccatura
                ? acc
                : acc + playbackTicks(for: g, mainTicks: mainTicks, division: division)
        }
        return min(raw, max(0, mainTicks / 2))
    }

    /// Time stolen from the *parent* chord's tail to fit
    /// after-graces. Same capping rule as the head.
    static func totalStealFromMainTail(
        _ after: [GraceChord], mainTicks: Int, division: Int
    ) -> Int {
        let raw = after.reduce(0) { acc, g in
            acc + playbackTicks(for: g, mainTicks: mainTicks, division: division)
        }
        return min(raw, max(0, mainTicks / 2))
    }
}
