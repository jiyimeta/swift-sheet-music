import Foundation
@testable import SheetMusicCore
import Testing

/// Tolerant equality comparison for the two `Score` trees produced by the
/// MusicXML importer (`Score_from_xml`) and the MSCX importer
/// (`Score_from_refMscx`) in the same fixture.
///
/// The two inputs describe the same music but differ in fields that **cannot
/// be reconstructed from MusicXML**:
/// - MuseScore's `.mscx` populates `Instrument.articulations` and channel
///   program/controllers from its internal `instruments.xml` template; the
///   MusicXML side has no equivalent.
/// - `.mscx` declares empty `metaTag name="arranger"/` etc.; MusicXML's
///   `<identification>` only names creators actually present.
/// - `Instrument.id` is format-dependent (`"flute"` in MSCX, `"wind.flutes.flute"`
///   or `"P1-I1"` in MusicXML).
/// - Integer pitch-range fields (`minPitchP`, `maxPitchP`, …) come from
///   MuseScore instrument templates.
///
/// The `.normalized` path strips those fields before comparing, so semantic
/// equivalence reflects the music notation itself rather than format noise.
enum ScoreSemanticComparison {
    struct Options: Sendable {
        /// If true (default), strip `metaTag` entries whose value is empty.
        var ignoreEmptyMetaTags = true
        /// If true (default), clear `Instrument.id`, playback-ranges, and
        /// `Instrument.articulations` + channel program/controllers (MuseScore
        /// template data with no MusicXML equivalent).
        var ignoreInstrumentPlaybackFields = true
        /// Additional meta-tag keys to drop from both sides before comparing.
        var ignoreMetaTagKeys: Set<String> = []
    }

    /// Assert that `produced` (from MusicXML) and `reference` (from MSCX)
    /// normalize to equal `Score` values. Emits a targeted diff message when
    /// they differ.
    static func assertEquivalent(
        produced: Score,
        reference: Score,
        options: Options = .init(),
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let lhs = normalize(produced, options: options)
        let rhs = normalize(reference, options: options)
        if lhs == rhs { return }

        var diffs: [String] = []
        if lhs.division != rhs.division {
            diffs.append("division: produced=\(lhs.division) reference=\(rhs.division)")
        }
        if lhs.metaTags != rhs.metaTags {
            let produced = lhs.metaTags.sorted(by: { $0.key < $1.key })
            let reference = rhs.metaTags.sorted(by: { $0.key < $1.key })
            diffs.append("metaTags differ:\n  produced=\(produced)\n  reference=\(reference)")
        }
        if lhs.parts.count != rhs.parts.count {
            diffs.append("parts.count: produced=\(lhs.parts.count) reference=\(rhs.parts.count)")
        } else {
            for (i, pair) in zip(lhs.parts, rhs.parts).enumerated()
            where pair.0 != pair.1 {
                diffs.append("parts[\(i)] differs:\n  produced=\(pair.0)\n  reference=\(pair.1)")
            }
        }
        if lhs.staves.count != rhs.staves.count {
            diffs.append("staves.count: produced=\(lhs.staves.count) reference=\(rhs.staves.count)")
        } else {
            for (i, pair) in zip(lhs.staves, rhs.staves).enumerated()
            where pair.0 != pair.1 {
                diffs.append(staffDiff(index: i, produced: pair.0, reference: pair.1))
            }
        }
        if diffs.isEmpty {
            diffs.append("Scores differ but no component diff pinpointed; full dump:")
            diffs.append("produced=\(lhs)")
            diffs.append("reference=\(rhs)")
        }
        Issue.record(
            Comment(rawValue: diffs.joined(separator: "\n")),
            sourceLocation: sourceLocation
        )
    }

    private static func staffDiff(index: Int, produced: StaffContent, reference: StaffContent) -> String {
        if produced.id != reference.id {
            return "staves[\(index)].id: produced=\(produced.id) reference=\(reference.id)"
        }
        if produced.measures.count != reference.measures.count {
            let p = produced.measures.count
            let r = reference.measures.count
            return "staves[\(index)].measures.count: produced=\(p) reference=\(r)"
        }
        for (m, pair) in zip(produced.measures, reference.measures).enumerated()
        where pair.0 != pair.1 {
            return measureDiff(staffIndex: index, measureIndex: m, produced: pair.0, reference: pair.1)
        }
        return "staves[\(index)] differs (structural)"
    }

    private static func measureDiff(
        staffIndex: Int,
        measureIndex: Int,
        produced: Measure,
        reference: Measure
    ) -> String {
        var msg = "staves[\(staffIndex)].measures[\(measureIndex)]: "
        if produced.startRepeat != reference.startRepeat {
            let p = produced.startRepeat
            let r = reference.startRepeat
            msg += "startRepeat produced=\(p) reference=\(r)"
            return msg
        }
        if produced.endRepeatCount != reference.endRepeatCount {
            let p = String(describing: produced.endRepeatCount)
            let r = String(describing: reference.endRepeatCount)
            msg += "endRepeatCount produced=\(p) reference=\(r)"
            return msg
        }
        if produced.voices.count != reference.voices.count {
            let p = produced.voices.count
            let r = reference.voices.count
            msg += "voices.count produced=\(p) reference=\(r)"
            return msg
        }
        if produced.markers != reference.markers {
            msg += "markers:\n  produced=\(produced.markers)\n  reference=\(reference.markers)"
            return msg
        }
        if produced.jumps != reference.jumps {
            msg += "jumps:\n  produced=\(produced.jumps)\n  reference=\(reference.jumps)"
            return msg
        }
        for (v, pair) in zip(produced.voices, reference.voices).enumerated()
        where pair.0.elements != pair.1.elements {
            msg += "voices[\(v)].elements differ:"
            let p = pair.0.elements
            let r = pair.1.elements
            let firstDiff = (0..<max(p.count, r.count)).first { i in
                let pi: VoiceElement? = i < p.count ? p[i] : nil
                let ri: VoiceElement? = i < r.count ? r[i] : nil
                return pi != ri
            }
            if let firstDiff {
                let pp = firstDiff < p.count ? "\(p[firstDiff])" : "(missing)"
                let rr = firstDiff < r.count ? "\(r[firstDiff])" : "(missing)"
                msg += "\n  first diff at [\(firstDiff)]:\n    produced:  \(pp)\n    reference: \(rr)"
                msg += "\n  produced elements: \(p.map { shortDesc($0) })"
                msg += "\n  reference elements: \(r.map { shortDesc($0) })"
            }
            return msg
        }
        return msg + "(unknown difference)"
    }

    private static func shortDesc(_ element: VoiceElement) -> String {
        switch element {
        case .chord(let c): return "chord(\(c.notes.map { $0.pitch }), \(c.duration))"
        case .rest(let r): return "rest(\(r.duration))"
        case .keySignature(let k): return "key(\(k.concertKey))"
        case .timeSignature(let t): return "time(\(t.numerator)/\(t.denominator))"
        case .clef(let c): return "clef(\(c.concertClefType))"
        case .barLine(let b): return "barline(\(b.subtype ?? ""))"
        case .tempo(let t): return "tempo(\(t))"
        case .dynamic(let d): return "dynamic(\(d))"
        case .spanner(let s): return "spanner(\(s.kind))"
        case .measureRepeat: return "measureRepeat"
        case .fermata(let f): return "fermata(\(f.subtype))"
        case .staffText(let st): return "staffText(\"\(st.text)\")"
        }
    }

    /// Produce a normalized copy of `score` suitable for field-by-field
    /// comparison across MusicXML / MSCX producers.
    static func normalize(_ score: Score, options: Options = .init()) -> Score {
        var s = score
        if options.ignoreEmptyMetaTags {
            s.metaTags = s.metaTags.filter { !$0.value.isEmpty }
        }
        for key in options.ignoreMetaTagKeys {
            s.metaTags.removeValue(forKey: key)
        }
        if options.ignoreInstrumentPlaybackFields {
            s.parts = s.parts.map { part in
                var p = part
                // Part.id is format-specific ("P1" in MusicXML, "1" in MSCX).
                p.id = ""
                var instr = p.instrument
                instr.id = ""
                instr.minPitchPlayable = nil
                instr.maxPitchPlayable = nil
                instr.minPitchAmateur = nil
                instr.maxPitchAmateur = nil
                instr.articulations = []
                instr.channels = [InstrumentChannel()]
                // MuseScore's .mscx exporter omits longName / shortName when
                // they match the instrument template's defaults (e.g. "Piano"
                // for a generic piano part), so they are nil on the MSCX
                // side but populated from <part-name>/<part-abbreviation>
                // on the MusicXML side. Drop both to avoid that asymmetry.
                instr.longName = nil
                instr.shortName = nil
                p.instrument = instr
                return p
            }
        }
        // Canonicalise all note durations to their Fraction-of-whole form so
        // `.whole` and `.fraction(1/1)` compare equal. MSCX emits
        // `<durationType>measure</durationType>` for whole-measure rests
        // (decoded as `.fraction`), while MusicXML's `<type>whole</type>`
        // lands on `.whole`. Both describe the same music.
        s.staves = s.staves.map { staff in
            var st = staff
            st.measures = st.measures.map { measure in
                var m = measure
                m.voices = m.voices.map { voice in
                    Voice(elements: voice.elements
                        // Strip staff/system text — only the MSCX
                        // decoder picks them up today, so keeping
                        // them would break cross-format equivalence
                        // of fixtures that round-trip through both.
                        .filter { element in
                            if case .staffText = element {
                                return false
                            }
                            return true
                        }
                        .map(canonicalizeDurations))
                }
                return m
            }
            return st
        }
        return s
    }

    private static func canonicalizeDurations(_ element: VoiceElement) -> VoiceElement {
        switch element {
        case .chord(var c):
            c.duration = canonicalDuration(c.duration)
            return .chord(c)
        case .rest(var r):
            r.duration = canonicalDuration(r.duration)
            return .rest(r)
        default:
            return element
        }
    }

    private static func canonicalDuration(_ d: NoteDuration) -> NoteDuration {
        switch d {
        case .whole:           return .fraction(Fraction(numerator: 1, denominator: 1))
        case .half:            return .fraction(Fraction(numerator: 1, denominator: 2))
        case .quarter:         return .fraction(Fraction(numerator: 1, denominator: 4))
        case .eighth:          return .fraction(Fraction(numerator: 1, denominator: 8))
        case .sixteenth:       return .fraction(Fraction(numerator: 1, denominator: 16))
        case .thirtySecond:    return .fraction(Fraction(numerator: 1, denominator: 32))
        case .sixtyFourth:     return .fraction(Fraction(numerator: 1, denominator: 64))
        case .oneTwentyEighth: return .fraction(Fraction(numerator: 1, denominator: 128))
        case .twoFiftySixth:   return .fraction(Fraction(numerator: 1, denominator: 256))
        case .fraction:        return d
        }
    }
}
