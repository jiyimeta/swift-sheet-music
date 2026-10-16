import Foundation
@testable import SheetMusicCore

/// The comparator's allowances for what MuseScore's MSCX writer puts in a file whatever the MusicXML said — each one an
/// `Options` flag naming the MuseScore field — and the system-lane diagnostic `assertEquivalent` prints.
extension ScoreSemanticComparison {
    /// Applies every writer allowance `options` switches on. Called last by `normalize`; `isReference` marks
    /// MuseScore's side.
    static func applyingWriterAllowances(_ score: Score, options: Options, isReference: Bool = false) -> Score {
        var s = score
        if options.ignoresPartTrackName {
            s.parts.mapValues { part in
                var copy = part
                copy.trackName = nil
                return copy
            }
        }
        if options.canonicalizesBracketColumns {
            s.parts = IdentifiedArray(Score.canonicalizingBracketColumns(s.parts.values))
        }
        if options.roundsTempoToFilePrecision { s = roundingTempos(s) }
        let touchesVoices = options.ignoresPedalAutoTextPlace || options.ignoresLineHairpinStyledTexts
            || options.ignoresDefaultFermataPlacement || options.normalizesTrailingEndMarkers
        guard touchesVoices else { return s }
        return mappingIndexedVoices(s) { index, isLastMeasure, voice in
            var elements = voice.elements.values.map { element in
                allowingWriterFields(element, voiceIndex: index, options: options)
            }
            if options.normalizesTrailingEndMarkers, isLastMeasure {
                elements = normalizingTrailingEndMarkers(elements, collapsingDuplicates: isReference)
            }
            var copy = voice
            copy.elements = IdentifiedArray(elements)
            return copy
        }
    }

    private static func allowingWriterFields(_ element: VoiceElement, voiceIndex: Int, options: Options)
        -> VoiceElement
    {
        switch element {
        case var .spanner(spanner):
            if options.ignoresPedalAutoTextPlace, spanner.kind == .pedal {
                spanner.payloadMarkup.removeAll(where: isAutoTextPlace)
            }
            if options.ignoresLineHairpinStyledTexts, spanner.hairpin?.subtype.isLineType == true {
                spanner.beginText = nil
                spanner.continueText = nil
            }
            return .spanner(spanner)
        case var .fermata(fermata) where options.ignoresDefaultFermataPlacement:
            let voiceDefault: Placement = voiceIndex.isMultiple(of: 2) ? .above : .below
            if fermata.elementProperties.placement == voiceDefault { fermata.elementProperties.placement = nil }
            return .fermata(fermata)
        default:
            return element
        }
    }

    /// Every tempo's beats per second at the 6 decimals MuseScore's writer keeps (`roundsTempoToFilePrecision`).
    private static func roundingTempos(_ score: Score) -> Score {
        var s = score
        s.systemMeasures.mapValues { measure in
            var copy = measure
            copy.elements.mapValues { entry in
                guard case var .tempo(tempo) = entry.element else { return entry }
                tempo.beatsPerSecond = (tempo.beatsPerSecond * 1_000_000).rounded() / 1_000_000
                var rounded = entry
                rounded.element = .tempo(tempo)
                return rounded
            }
            return copy
        }
        return s
    }

    private static func isAutoTextPlace(_ markup: PreservedXML) -> Bool {
        (markup.name == "continueTextPlace" || markup.name == "endTextPlace") && markup.text == "auto"
    }

    /// In the maximal trailing run of bar lines and spanner end markers (when it holds a bar line): end markers first,
    /// in their order, then the bar lines; with `collapsingDuplicates` (the reference side, whose 4.x writer doubles
    /// an end on the score's last tick) identical consecutive end markers become one.
    static func normalizingTrailingEndMarkers(
        _ elements: [VoiceElement], collapsingDuplicates: Bool,
    ) -> [VoiceElement] {
        var start = elements.count
        while start > 0, trailingRunRank(elements[start - 1]) != nil {
            start -= 1
        }
        let run = elements[start...]
        guard run.contains(where: { trailingRunRank($0) == 1 }) else { return elements }
        var markers: [VoiceElement] = []
        for element in run where trailingRunRank(element) == 0 {
            if collapsingDuplicates, markers.last == element { continue }
            markers.append(element)
        }
        let barLines = run.filter { trailingRunRank($0) == 1 }
        return Array(elements[..<start]) + markers + barLines
    }

    /// 0 for a spanner end marker, 1 for a bar line, `nil` for anything that ends the trailing run.
    private static func trailingRunRank(_ element: VoiceElement) -> Int? {
        switch element {
        case let .spanner(spanner) where spanner.isEndMarker: 0
        case .barLine: 1
        default: nil
        }
    }

    /// Every voice through `transform(voice index, whether its measure is the staff's last, voice)`.
    private static func mappingIndexedVoices(
        _ score: Score, _ transform: @escaping (Int, Bool, Voice) -> Voice,
    ) -> Score {
        var s = score
        s.parts.mapValues { part in
            var pt = part
            pt.staves.mapValues { staff in
                var st = staff
                let lastIndex = st.measures.count - 1
                st.measures = st.measures.enumerated().map { measureIndex, measure in
                    var m = measure
                    m.voices = m.voices.enumerated().map { transform($0.offset, measureIndex == lastIndex, $0.element) }
                    return m
                }
                return st
            }
            return pt
        }
        return s
    }

    /// The first difference in `Score.systemMeasures` (tempo, staff text, play-technique text, rehearsal marks): the
    /// count, else the first differing measure and its first differing element. `nil` when the lanes are equal.
    static func systemMeasuresDiff(produced: Score, reference: Score) -> String? {
        let lhs = produced.systemMeasures
        let rhs = reference.systemMeasures
        if lhs.count != rhs.count {
            return "systemMeasures.count: produced=\(lhs.count) reference=\(rhs.count)"
        }
        guard let m = (0 ..< lhs.count).first(where: { lhs[$0] != rhs[$0] }) else { return nil }
        let p = lhs[m].elements.values
        let r = rhs[m].elements.values
        var msg = "systemMeasures[\(m)]: "
        guard let i = (0 ..< max(p.count, r.count)).first(where: { k in
            let pk: PositionedSystemElement? = k < p.count ? p[k] : nil
            let rk: PositionedSystemElement? = k < r.count ? r[k] : nil
            return pk != rk
        }) else {
            return msg + "(differs outside its elements)\n  produced=\(lhs[m])\n  reference=\(rhs[m])"
        }
        let pp = i < p.count ? "\(p[i])" : "(missing)"
        let rr = i < r.count ? "\(r[i])" : "(missing)"
        msg += "first diff at [\(i)] (produced \(p.count), reference \(r.count) elements):"
        return msg + "\n    produced:  \(pp)\n    reference: \(rr)"
    }
}
