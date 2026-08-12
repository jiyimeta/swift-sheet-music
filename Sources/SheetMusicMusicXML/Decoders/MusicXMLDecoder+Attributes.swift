import Foundation
import SheetMusicCore
import SheetMusicXMLTools

/// Decodes `<attributes>` into a sequence of `Emission`s (clef, key, time) and
/// updates the current divisions as a side effect. Mirrors MuseScore's
/// behavior of only emitting changed attributes in the measure stream; the
/// initial measure always emits all three (save that C-major keysigs are
/// suppressed, matching `.mscx` exporter output).
enum AttributesDecoder {
    /// One emitted attribute, optionally targeted at a specific staff (0-based).
    /// `staffIndex == nil` means "broadcast to every staff in the part"
    /// (used for `<key>` and `<time>`). `<clef number="N">` sets
    /// `staffIndex` to `N - 1`.
    struct Emission {
        let staffIndex: Int?
        let element: VoiceElement
    }

    static func decode(
        node: XMLTreeNode,
        divisions: inout DivisionsContext,
        previous: inout MusicXMLAttributesSnapshot,
        isFirstMeasure: Bool,
        staffCount: Int,
    ) -> [Emission] {
        if let divText = node.first("divisions")?.text,
           let div = Int(divText), div > 0
        {
            divisions.perQuarter = div
        }

        decodeStaffLines(node, previous: &previous, staffCount: staffCount)

        var output: [Emission] = []
        output.append(contentsOf: decodeClefs(
            node,
            previous: &previous,
            isFirstMeasure: isFirstMeasure,
            staffCount: staffCount,
        ))

        if let fifths = decodeKeyFifths(node) {
            let changed = fifths != previous.keyFifths
            // MuseScore's `.mscx` exporter omits `<KeySig>` for C major
            // (fifths = 0) when it hasn't changed, treating it as the
            // implicit default. Match that for semantic parity.
            let shouldEmit: Bool
            if isFirstMeasure {
                shouldEmit = fifths != 0
            } else {
                shouldEmit = changed
            }
            if shouldEmit {
                output.append(Emission(
                    staffIndex: nil,
                    element: .keySignature(KeySignature(concertKey: fifths)),
                ))
            }
            previous.keyFifths = fifths
        }

        if let (n, d) = decodeTime(node) {
            let changed = n != previous.timeN || d != previous.timeD
            if isFirstMeasure || changed {
                output.append(Emission(
                    staffIndex: nil,
                    element: .timeSignature(TimeSignature(
                        numerator: n,
                        denominator: d,
                    )),
                ))
                previous.timeN = n
                previous.timeD = d
            }
        }

        return output
    }

    /// Decode every `<clef>` in the attributes. The `number` attribute (1-based
    /// staff index) selects the target staff; unspecified defaults to 1.
    /// Per-staff previous-clef state is kept in `previous.clefByStaff` so we
    /// only emit Clef changes.
    private static func decodeClefs(
        _ node: XMLTreeNode,
        previous: inout MusicXMLAttributesSnapshot,
        isFirstMeasure: Bool,
        staffCount: Int,
    ) -> [Emission] {
        var output: [Emission] = []
        for clefNode in node.all("clef") {
            let sign = clefNode.first("sign")?.text ?? ""
            let line = clefNode.first("line")?.text ?? ""
            guard let concert = musicXMLClefToMuseScore(sign: sign, line: line) else {
                continue
            }
            let number = clefNode.attributes["number"].flatMap { Int($0) } ?? 1
            let staffIndex = max(0, min(staffCount - 1, number - 1))
            let prior = previous.clefByStaff[staffIndex]
            if isFirstMeasure || prior != concert {
                output.append(Emission(
                    staffIndex: staffIndex,
                    element: .clef(Clef(
                        concertClefType: concert,
                        transposingClefType: concert,
                    )),
                ))
                previous.clefByStaff[staffIndex] = concert
            }
        }
        return output
    }

    /// Record every `<staff-details><staff-lines>N</staff-lines>` into
    /// `previous.lineCountByStaff`. Unlike clef / key / time this is a
    /// *staff-level* property, not a `VoiceElement`, so it has no
    /// `Emission` — it rides the snapshot up to the part decoder, which
    /// stamps it onto the `Staff` values it builds.
    ///
    /// `number` is a 1-based staff selector; an absent `number` means
    /// staff 1. An out-of-range `number` falls back to the FIRST staff
    /// rather than being clamped to the last, mirroring
    /// `MusicXmlParserPass2::staffDetails`
    /// (`importmusicxmlpass2.cpp:3141-3149`), which logs
    /// "invalid staff-details number" and resets its index to 0.
    /// Note this deliberately differs from `decodeClefs` above, which
    /// clamps; changing clef targeting is a separate behavioral change.
    ///
    /// `SheetMusicMusicXML` has no `mscxDecoderWarn` equivalent, so an
    /// out-of-range or non-numeric value is corrected silently rather
    /// than diagnosed — matching the target policy (clamp to `1...16`,
    /// fall back to 5) without inventing a diagnostic channel.
    private static func decodeStaffLines(
        _ node: XMLTreeNode,
        previous: inout MusicXMLAttributesSnapshot,
        staffCount: Int,
    ) {
        for detailsNode in node.all("staff-details") {
            guard let raw = detailsNode.first("staff-lines")?.text,
                  let parsed = Int(raw)
            else { continue }
            let number = detailsNode.attributes["number"].flatMap { Int($0) } ?? 1
            let staffIndex = (1 ... max(1, staffCount)).contains(number) ? number - 1 : 0
            previous.lineCountByStaff[staffIndex] = min(max(parsed, 1), 16)
        }
    }

    private static func decodeKeyFifths(_ node: XMLTreeNode) -> Int? {
        guard let keyNode = node.first("key") else {
            return nil
        }
        return keyNode.first("fifths").flatMap { Int($0.text) }
    }

    private static func decodeTime(_ node: XMLTreeNode) -> (Int, Int)? {
        guard let timeNode = node.first("time"),
              let beatsText = timeNode.first("beats")?.text,
              let beatTypeText = timeNode.first("beat-type")?.text,
              let n = Int(beatsText), let d = Int(beatTypeText)
        else {
            return nil
        }
        return (n, d)
    }

    /// Map MusicXML `<sign>`/`<line>` to MuseScore's `concertClefType` value.
    private static func musicXMLClefToMuseScore(sign: String, line: String) -> String? {
        switch (sign, line) {
        case ("G", "2"): return "G"
        case ("G", "1"): return "G8va"
        case ("F", "4"): return "F"
        case ("F", "3"): return "F_B"
        case ("C", "1"): return "C1"
        case ("C", "2"): return "C2"
        case ("C", "3"): return "C3"
        case ("C", "4"): return "C4"
        case ("C", "5"): return "C5"
        case ("percussion", _): return "PERC"
        default:
            // Unknown clef combinations are skipped silently — matches the
            // permissive "drop what we can't represent" posture of the MSCX
            // decoder.
            return nil
        }
    }
}

/// Snapshot of the most recent `<attributes>` values. Lives outside the enum so
/// `MusicXMLDecoder+Measure.swift` can hold an `inout` across loop iterations
/// without an unnecessary nesting trip. `clefByStaff` and
/// `lineCountByStaff` are keyed by 0-based staff index.
struct MusicXMLAttributesSnapshot {
    var clefByStaff: [Int: String] = [:]
    /// `<staff-details><staff-lines>` per staff, already clamped to
    /// `1...16`. A staff absent from the map keeps `Staff.lineCount`'s
    /// default of 5.
    var lineCountByStaff: [Int: Int] = [:]
    var keyFifths: Int?
    var timeN: Int?
    var timeD: Int?
}
