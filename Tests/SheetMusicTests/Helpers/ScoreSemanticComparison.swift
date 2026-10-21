// swiftformat:disable all
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
        /// If true, drop every `.staffText` system element before comparing. Off by default since the MusicXML
        /// importer reads `<words>` as MuseScore does.
        var stripsStaffText = false
        /// If true, stable-sort each run of untimed annotations (MuseScore's order inside a segment is arbitrary).
        var sortsAnnotationRuns = false
        /// If true, clear line geometry (hook heights, dash lengths) that MusicXML cannot carry.
        var ignoresLineGeometry = false
        /// If true, clear `Part.trackName` — the `<Part><trackName>` MuseScore 4.x's writer emits (from the part name)
        /// and master's no longer does (`twrite.cpp`, `Part::partName()` derived). The MusicXML decoder leaves it nil.
        var ignoresPartTrackName = false
        /// If true, drop a pedal's `<continueTextPlace>auto</continueTextPlace>` / `<endTextPlace>auto</endTextPlace>`
        /// payload children — Pid::CONTINUE_TEXT_PLACE / END_TEXT_PLACE, which `Pedal::Pedal` leaves at AUTO while
        /// their default is LEFT (`pedal.cpp:122,161-164`), so every pedal MuseScore saves writes both, whatever the
        /// input said.
        var ignoresPedalAutoTextPlace = false
        /// If true, clear `beginText` / `continueText` on cresc. / dim. line hairpins (`crescLine` / `dimLine`). Those
        /// texts are style-bound (`hairpin.cpp:53,59`, Sid::hairpinText) and MuseScore's importer sets them by setter
        /// (`importmusicxmlpass2.cpp:4560-4561`), leaving them STYLED, so its file never carries them.
        var ignoresLineHairpinStyledTexts = false
        /// If true, clear a fermata's placement when it equals its voice's default — MuseScore writes Pid::PLACEMENT
        /// only when it differs from the track's default, above for an even track, below for an odd one
        /// (`fermata.cpp:190-191`); the MusicXML decoder sets it explicitly.
        var ignoresDefaultFermataPlacement = false
        /// If true, in the trailing run of bar lines and spanner end markers of each voice of each staff's LAST measure
        /// only, put the end markers before the bar lines on both sides, and collapse identical consecutive end
        /// markers on the reference side only. MuseScore 4.x's MSCX writer writes a spanner ending on the score's
        /// last tick twice and before the end bar line; other versions write one, after it. A duplicate end on the
        /// produced side is a decoder fault and still fails.
        var normalizesTrailingEndMarkers = false
        /// If true, compact bracket columns onto `0 ..< n` on both sides (`Score.canonicalizingBracketColumns`).
        /// MuseScore numbers a bracket's `<bracket col>` / `<level>` by level (an implicit brace is
        /// `bracketLevels + 1`, so column 1 over an empty column 0) and draws an empty column at no width; the
        /// import compacts the columns, so the drawn gutter is the same while the numbers differ.
        var canonicalizesBracketColumns = false
        /// If true, round every tempo's beats per second to 6 decimals — the precision MuseScore's writer gives
        /// Pid::TEMPO (`TConv::toXml(tempo, Constants::TEMPO_PRECISION)`, `twrite.cpp:3327`, `constants.h:110`), so a
        /// reference file holds 1.666667 where the import's exact value is 100 / 60.
        var roundsTempoToFilePrecision = false
        /// If true, keep text formatting and the direction elements' sides through the preserved-markup strip
        /// (`strippingPreservedMarkupKeepingText`): `preservedTextMarkup` on staff / system texts, tempos, rehearsal
        /// marks, swings, instrument changes, markers, jumps, dynamics, Expressions and Stickings, and the
        /// `<direction>` children of dynamics and Expressions. Off by default, which strips them with the rest.
        var keepsTextMarkup = false
        /// If true, set every syllable's melisma length (`Lyric.ticks`) to 0 on both sides. The MusicXML decoder does
        /// not read `<extend>` yet, while MuseScore's import turns it into the `<ticks_f>` its refs carry — a known
        /// gap, which went unseen while the MSCX decoder dropped `<ticks_f>` too.
        var ignoresLyricMelismas = false
    }

    /// The `metaTag` keys MuseScore's app (not its importer) writes when `mscore` saves outside test mode:
    /// `creationDate` / `platform` (`writer.cpp:172-173` drops them only under `MScore::testMode`) and
    /// `originalFormat` (`notationproject.cpp:354`, set on open). For `Options.ignoreMetaTagKeys`.
    static let appWrittenMetaTagKeys: Set<String> = ["creationDate", "platform", "originalFormat"]

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
        let rhs = normalize(reference, options: options, isReference: true)
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
                where pair.0 != pair.1
            {
                diffs.append("parts[\(i)] differs:\n  produced=\(pair.0)\n  reference=\(pair.1)")
            }
        }
        let lhsStaves = lhs.allStaves.map(\.staff)
        let rhsStaves = rhs.allStaves.map(\.staff)
        if lhsStaves.count != rhsStaves.count {
            diffs.append("staves.count: produced=\(lhsStaves.count) reference=\(rhsStaves.count)")
        } else {
            for (i, pair) in zip(lhsStaves, rhsStaves).enumerated()
                where pair.0 != pair.1
            {
                diffs.append(staffDiff(index: i, produced: pair.0, reference: pair.1))
            }
        }
        if let lane = systemMeasuresDiff(produced: lhs, reference: rhs) { diffs.append(lane) }
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

    private static func staffDiff(index: Int, produced: Staff, reference: Staff) -> String {
        if produced.measures.count != reference.measures.count {
            let p = produced.measures.count
            let r = reference.measures.count
            return "staves[\(index)].measures.count: produced=\(p) reference=\(r)"
        }
        for (m, pair) in zip(produced.measures, reference.measures).enumerated()
            where pair.0 != pair.1
        {
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
            where pair.0.elements != pair.1.elements
        {
            msg += "voices[\(v)].elements differ:"
            let p = pair.0.elements
            let r = pair.1.elements
            let firstDiff = (0 ..< max(p.count, r.count)).first { i in
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

    // swiftformat:disable:next redundantPattern
    private static func shortDesc(_ element: VoiceElement) -> String {
        switch element {
        case let .chord(c):
            return c.notes.isEmpty ? "rest(\(c.duration))"
                : "chord(\(c.notes.map { $0.pitch }), \(c.duration))"
        case let .keySignature(k): return "key(\(k.concertKey))"
        case let .timeSignature(t): return "time(\(t.numerator)/\(t.denominator))"
        case let .clef(c): return "clef(\(c.concertClefType))"
        case let .barLine(b): return "barline(\(b.subtype ?? ""))"
        case let .dynamic(d): return "dynamic(\(d))"
        case let .spanner(s): return "spanner(\(s.kind))"
        case .measureRepeat: return "measureRepeat"
        case let .fermata(f): return "fermata(\(f.subtype))"
        case let .breath(b): return "breath(\(b.kind))"
        case let .harmony(h): return "harmony(\"\(h.name)\")"
        case let .sticking(s): return "sticking(\"\(s.text)\")"
        case let .expression(e): return "expression(\"\(e.text)\")"
        case let .capo(c): return "capo(\(c.fretPosition))"
        case let .stringTunings(t): return "stringTunings(\"\(t.preset)\")"
        case let .ambitus(a): return "ambitus(\(a.topPitch)-\(a.bottomPitch))"
        case let .figuredBass(fb):
            return fb.items.isEmpty ? "figuredBass(\"\(fb.text)\")" : "figuredBass(\(fb.items.count) items)"
        case let .symbol(s): return "symbol(\"\(s.name)\")"
        case let .fretDiagram(diagram):
            return "fretDiagram(\(diagram.strings.count) strings)"
        case let .locationShift(delta):
            return "locationShift(\(delta.numerator)/\(delta.denominator))"
        case let .preserved(markup): return "preserved(<\(markup.name)>)"
        }
    }

    /// Produce a normalized copy of `score` suitable for field-by-field
    /// comparison across MusicXML / MSCX producers. `isReference` marks MuseScore's side, which one allowance treats
    /// differently (`normalizesTrailingEndMarkers`).
    static func normalize(_ score: Score, options: Options = .init(), isReference: Bool = false) -> Score {
        var s = score
        // Frames — the title block (`<VBox>`) and the horizontal, text, and
        // fret frames beside it — are page furniture with no MusicXML
        // equivalent, so drop them from both sides and keep the comparison on
        // the notation itself. Clearing `blocks` is what does it now that
        // `titleFrame` is a view onto the leading vertical frame: setting that
        // alone would leave a mid-score `<HBox>` on the MSCX side, which the
        // MusicXML side can never produce.
        s.blocks = []
        // `<Style>` block (page geometry, spatium, header/footer chrome)
        // and `<LayoutBreak>` markers are MSCX-only page-layout metadata —
        // the MusicXML decoder doesn't translate them. Reset to defaults
        // on both sides so the comparison reflects the music itself.
        s.style = .museScoreDefaults
        // `source` is loader-set; MusicXML and MSCX inputs naturally
        // disagree. Clear it so the comparison reflects the notation.
        s.source = .unknown
        // Preserved markup is verbatim MSCX the model does not
        // represent (`PreservedXML`). The MusicXML side has no
        // counterpart and never will, so the MSCX side would always
        // carry `<Order>`, `<Synthesizer>`, and the rest that the
        // other side cannot. Strip it for the same reason `style` is
        // reset: it is not the notation.
        s = options.keepsTextMarkup ? strippingPreservedMarkupKeepingText(s) : s.strippingPreservedMarkup()
        if options.ignoreEmptyMetaTags {
            s.metaTags = s.metaTags.filter { !$0.value.isEmpty }
        }
        for key in options.ignoreMetaTagKeys {
            s.metaTags.removeValue(forKey: key)
        }
        if options.ignoreInstrumentPlaybackFields {
            s.parts.mapValues { part in
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
        // (decoded as `.measure`), while MusicXML's `<type>whole</type>`
        // lands on `.whole`. Both describe the same music; we normalize
        // `.measure` to `.fraction(1/1)` for cross-format comparison
        // (the actual bar duration is unknowable from a NoteDuration in
        // isolation — measure-resolution happens in renderers / encoders).
        s.parts.mapValues { part in
            var pt = part
            pt.staves.mapValues { staff in
                var st = staff
                st.measures = st.measures.map { measure in
                    var m = measure
                    m.lineBreak = false
                    m.pageBreak = false
                    m.voices = m.voices.map { voice in
                        Voice(elements: voice.elements
                            .map(canonicalizeDurations))
                    }
                    return m
                }
                return st
            }
            return pt
        }
        if options.stripsStaffText { s = removingStaffText(s) }
        if options.sortsAnnotationRuns { s = sortingAnnotationRuns(s) }
        if options.ignoresLineGeometry { s = ignoringLineGeometry(s) }
        if options.ignoresLyricMelismas { s = clearingLyricMelismas(s) }
        return applyingWriterAllowances(s, options: options, isReference: isReference)
    }

    private static func clearingLyricMelismas(_ score: Score) -> Score {
        var s = score
        s.parts.mapValues { part in
            var pt = part
            pt.staves.mapValues { staff in
                var st = staff
                st.measures = st.measures.map { measure in
                    var m = measure
                    m.voices = m.voices.map { voice in
                        Voice(elements: voice.elements.map { element in
                            guard case var .chord(chord) = element else { return element }
                            chord.lyrics = chord.lyrics.map { lyric in
                                var cleared = lyric
                                cleared.ticks = 0
                                return cleared
                            }
                            return .chord(chord)
                        })
                    }
                    return m
                }
                return st
            }
            return pt
        }
        return s
    }

    private static func canonicalizeDurations(_ element: VoiceElement) -> VoiceElement {
        guard case let .chord(c) = element else { return element }
        var updated = c
        updated.duration = canonicalDuration(c.duration)
        return .chord(updated)
    }

    private static func canonicalDuration(_ d: NoteDuration) -> NoteDuration {
        switch d {
        case .whole: return .fraction(Fraction(numerator: 1, denominator: 1))
        case .half: return .fraction(Fraction(numerator: 1, denominator: 2))
        case .quarter: return .fraction(Fraction(numerator: 1, denominator: 4))
        case .eighth: return .fraction(Fraction(numerator: 1, denominator: 8))
        case .sixteenth: return .fraction(Fraction(numerator: 1, denominator: 16))
        case .thirtySecond: return .fraction(Fraction(numerator: 1, denominator: 32))
        case .sixtyFourth: return .fraction(Fraction(numerator: 1, denominator: 64))
        case .oneTwentyEighth: return .fraction(Fraction(numerator: 1, denominator: 128))
        case .twoFiftySixth: return .fraction(Fraction(numerator: 1, denominator: 256))
        case .breve: return .fraction(Fraction(numerator: 2, denominator: 1))
        case .long: return .fraction(Fraction(numerator: 4, denominator: 1))
        case .fraction: return d
        case .measure: return .fraction(Fraction(numerator: 1, denominator: 1))
        }
    }
}
