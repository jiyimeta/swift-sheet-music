import SheetMusicFoundation

/// A deterministic 64-bit digest of everything score *editing* can change, for comparing two copies of a score that
/// live in different processes or — on Android — in two separately linked images of this module.
///
/// Deliberately not built on `Hashable` / `Hasher`: those are seeded per process, so two images would disagree about
/// identical scores. FNV-1a is fixed by its constants and gives the same answer everywhere.
///
/// Scope is the mutable musical content — element kind, timing, pitch, spelling, ties, tuplet ratios. Everything
/// else is out, which keeps the walk cheap, but "engraving trivia" undersells how much that actually excludes —
/// spelled out here so the next person adding an intent knows exactly what this walk is blind to, rather than
/// discovering it by omission:
///
/// - `Chord.elementProperties` IS covered, by occupants: `visible == false` and a set `color` each feed a
///   unique tag; a default (visible, uncolored) chord feeds nothing. See `ScoreFingerprintHasher+Parity.swift`.
/// - `Note.elementProperties.color` IS covered the same way — `visible` was already fed unconditionally via
///   `Note.visible`. Still not covered: `fret` and `string` (the tablature position, a rendering of the pitch
///   this walk already covers) and `guitarBend` / `guitarBendBack` (import-only notation, set by no edit
///   command).
/// - `Chord.spanners` IS covered, by occupants: a chord carrying one or more spanner begins (a slur, in
///   practice) feeds tag 32, the count and each spanner's identity via `combine(_ spanner:)`; a chord with an
///   empty array feeds nothing, so every score without slurs hashes as it did before. Added with group 6's
///   `SetSlur` / `RemoveSpanner`. See `ScoreFingerprintHasher+Parity.swift`.
/// - Not covered within the nested types the walk now recurses into: `Arpeggio.elementProperties`,
///   `Lyric.elementProperties`, and `ChordLine.elementProperties` (visibility/color on those attachments, same
///   reasoning as the two bullets above), plus `Lyric.properties` (text positioning/formatting) and
///   `ChordLine.path` (hand-drawn Bezier control points) — all display-only, none of it set by any edit command
///   in this package today.
/// - `Measure`'s `startRepeat`, `endRepeatCount`, `measureRepeatCount`, `markers`, `jumps`, `lineBreak`,
///   `pageBreak`, `sectionBreak` ARE covered, by occupants — see `ScoreFingerprintHasher+Parity.swift`'s
///   `combineFlags(_:)`. `actualLength` and `irregular` were already covered — M3's re-barring writes both — and
///   so is `Staff.measures.count`; `Staff.defaultClefType` is not.
/// - Not covered on the system lane: `Score.systemMeasures`'s ELEMENTS are covered (measure index, position and the
///   fields that give each one its musical identity), but the lane's LENGTH is not — an empty `SystemMeasure` and an
///   absent one are indistinguishable to this walk, deliberately, so that a score built in memory and the same score
///   parsed from MSCX still agree; see `combineSystemLane`. Nor is the display trivia hanging off each element —
///   `offsetX` / `offsetY`, `properties` (fonts), `elementProperties` (visibility/color), `RehearsalMark.frame`,
///   `InstrumentChange.isUserInitialized`. Same reasoning as the `Chord` / `Note` bullets above.
/// - The walk's own shape: it emits a flat sequence of staff blocks with no part/staff-count delimiter, so two
///   scores whose staves are grouped into parts differently — but which total the same number of staves — hash
///   identically.
///
/// None of the above is reachable by any `EditIntent` this package accepts today, so the walk's contract still
/// holds: a difference it cannot see is a missed detection, never a false alarm. But that contract is only as good
/// as this list — the next edit command that touches one of these fields must add it here, not assume it already
/// is.
extension Score {
    public var stableFingerprint: Int64 {
        var hash = FNV1a()
        for part in parts {
            for staff in part.staves {
                hash.combine(staff.measures.count)
                for measure in staff.measures {
                    hash.combine(measure.actualLength)
                    hash.combine(measure.irregular)
                    hash.combineFlags(measure) // by occupants — feeds nothing for a default measure
                    hash.combine(measure.voices.count)
                    for voice in measure.voices {
                        hash.combine(voice.elements.count)
                        for element in voice.elements {
                            hash.combine(element)
                        }
                        hash.combine(voice.tuplets.count)
                        for tuplet in voice.tuplets {
                            hash.combine(tuplet.actualNotes)
                            hash.combine(tuplet.normalNotes)
                            hash.combine(tuplet.startIndex)
                            hash.combine(tuplet.endIndex)
                        }
                    }
                }
            }
        }
        hash.combineSystemLane(systemMeasures)
        return Int64(bitPattern: hash.value)
    }
}

extension FNV1a {
    /// Feeds `Score.systemMeasures` by its OCCUPANTS rather than by its length: a score built in memory leaves the
    /// array empty, while the same score parsed from MSCX carries one (usually empty) `SystemMeasure` per bar, and a
    /// walk that hashed `systemMeasures.count` would call those two spellings of the same score different. Every
    /// element carries its own measure index instead, so an empty lane and an absent one feed identical bytes while a
    /// tempo that moved between bars — which is exactly what a re-bar does to one — still shows.
    ///
    /// The total element count goes in first for the reason `combine(_ string:)` is length-prefixed: without it two
    /// adjacent elements could blur into one, and the lane is the last thing the walk feeds, so nothing else would
    /// delimit it.
    fileprivate mutating func combineSystemLane(_ systemMeasures: [SystemMeasure]) {
        var elementCount = 0
        for systemMeasure in systemMeasures {
            elementCount += systemMeasure.elements.count
        }
        combine(elementCount)
        for (measureIndex, systemMeasure) in systemMeasures.enumerated() {
            for positioned in systemMeasure.elements {
                combine(measureIndex)
                combine(positioned.position.offset)
                combine(positioned.originalStaff)
                combine(positioned.element)
            }
        }
    }
}
