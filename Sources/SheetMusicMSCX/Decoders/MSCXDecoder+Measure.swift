import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Measure {
    /// Every `<Measure>` child this decoder reads directly or passes
    /// to the flat-form voice decoder. Anything else becomes
    /// preserved markup — see `PreservedXML`.
    ///
    /// `LayoutBreak` is deliberately absent. A tag-name set cannot
    /// distinguish the modeled `line` / `page` / `section` subtypes
    /// from the unmodeled `nobreak` subtype, so
    /// `preservedMeasureMarkup(in:)` handles that tag explicitly.
    ///
    /// `stretch` and `noOffset` are absent for a plainer reason: nothing
    /// reads them. They were listed here, which took them out of the
    /// preserved-markup bag without putting them anywhere else, so a
    /// user stretch and a measure-number offset were silently deleted on
    /// save. **Consuming a tag the model does not store is strictly
    /// worse than not consuming it** — the bag is what would otherwise
    /// have carried it. They still have to be skipped when bucketing an
    /// MS2 flat-form measure into voices, which `decodeMS2FlatVoices`
    /// does from its own list.
    ///
    /// `multiMeasureRest` stays. It marks a measure MuseScore
    /// synthesizes from the ones it replaces, and the staff decoder
    /// drops that whole measure (`isMultiMeasureRestContainer`) because
    /// MuseScore regenerates it from the style flag.
    private static let consumedMeasureChildren: Set = [
        "BarLine", "Beam", "Breath", "Chord", "Clef", "Dynamic",
        "Fermata", "Harmony", "InstrumentChange", "Jump", "KeySig",
        "Marker", "MeasureRepeat", "RehearsalMark", "RepeatMeasure",
        "Rest", "Spanner", "StaffText", "SystemText", "Tempo",
        "TimeSig", "Tuplet", "endRepeat", "endTuplet", "irregular",
        "location", "measureRepeatCount", "multiMeasureRest",
        "startRepeat", "tick", "voice",
    ]

    private static let modeledLayoutBreakSubtypes: Set = [
        "line", "page", "section",
    ]

    private static let consumedMarkerChildren: Set = [
        "label", "markerType", "text",
    ]

    private static let consumedJumpChildren: Set = [
        "continueAt", "jumpTo", "playRepeats", "playUntil", "text",
    ]

    /// Decoded `Measure` plus any system-level elements lifted out
    /// of its voices during decoding. The caller stamps each
    /// `PositionedSystemElement.originalStaff` with the appropriate
    /// `StaffAddress` once the part/staff index is known (see
    /// `assembleParts(decoded:topLevel:)`).
    struct DecodeResult {
        let measure: Measure
        let systemElements: [PositionedSystemElement]
    }

    /// True when a raw `<Measure>` XML node is MuseScore's mmRest
    /// "annotation container" (`<Measure len="K×ts"><multiMeasureRest>K>`)
    /// rather than a real bar.
    ///
    /// MuseScore writes a K-bar multi-measure rest as K+1 sibling
    /// `<Measure>` entries: one regular rest measure leading the run,
    /// the mmRest container, then K-1 regular rest measures trailing.
    /// The container's own `<voice>` carries an oddly-shaped rest
    /// (e.g. `<duration>8/4>` for any K) — it isn't a bar, just the
    /// "this run of K rest bars renders as one H-bar with the number
    /// K above" hint that older readers used to lay out the visual.
    ///
    /// Counting it as a bar inflates the bar count by one per mmRest
    /// section (m111-115 instead of m111-114 for a 4-bar group). The
    /// surrounding K real rest measures are kept; the layout-time
    /// `MultiMeasureRestPlanner` collapses them on demand.
    static func isMultiMeasureRestContainer(_ node: XMLTreeNode) -> Bool {
        node.children.contains(where: { $0.name == "multiMeasureRest" })
    }

    /// Convenience that drops lifted system elements. Most callers
    /// only need the measure shape; full `DecodeResult` is for code
    /// that wires `originalStaff`-stamped system elements into
    /// `Score.systemMeasures`.
    static func decode(_ node: XMLTreeNode) throws -> Measure {
        try decodeWithSystemElements(node).measure
    }

    static func decodeWithSystemElements(_ node: XMLTreeNode) throws -> DecodeResult {
        let startRepeat = node.children.contains(where: { $0.name == "startRepeat" })
        let endRepeatCount = node.first("endRepeat").flatMap { Int($0.text) }
        let measureRepeatCount = node.first("measureRepeatCount").flatMap { Int($0.text) }

        let voiceNodes = node.all("voice")
        let voiceResults: [Voice.DecodeResult]
        if !voiceNodes.isEmpty {
            voiceResults = try voiceNodes.map { try Voice.decodeWithSystemElements($0) }
        } else if hasMS2NonZeroVoiceContent(node) {
            // MS2 flat form: <Measure> interleaves all voices, with
            // `<track>N</track>` on each Chord/Rest and `<tick>X</tick>`
            // resetting the absolute-tick cursor between voice groups.
            // Demux by (track mod 4) so non-default voices land in
            // their own `Voice` and don't get appended to voice 0.
            voiceResults = try decodeMS2FlatVoices(measure: node)
        } else {
            // Older / simpler mscx form: musical elements are direct children of
            // <Measure> (no <voice> wrapper). Treat them as a single implicit voice.
            voiceResults = try [Voice.decodeWithSystemElements(node)]
        }
        let voices = voiceResults.map(\.voice)
        let systemElements = voiceResults.flatMap(\.systemElements)
        let markers = node.all("Marker").map(decodeMarker)
        let jumps = node.all("Jump").map(decodeJump)
        // `<LayoutBreak>` declares an explicit system / page / section
        // break after this measure. `line` starts a new system, `page`
        // a new page; `section` additionally bounds playback
        // navigation (repeat unrolling and jump-target resolution
        // reset at section boundaries).
        var lineBreak = false
        var pageBreak = false
        var sectionBreak = false
        for lb in node.all("LayoutBreak") {
            switch lb.first("subtype")?.text {
            case "line": lineBreak = true
            case "page": pageBreak = true
            case "section": sectionBreak = true
            default: break
            }
        }

        // `<Measure len="N/D">` — actual length when it differs from
        // the prevailing time signature. Malformed values fall back to
        // nil; the parser stays permissive about optional metadata.
        let actualLength = node.attributes["len"]
            .flatMap(Fraction.init(mscxString:))
        // `<irregular>1</irregular>` — exclude this measure from the
        // running displayed measure number (typical on anacrusis).
        let irregular = node.first("irregular")?.text == "1"
        let preservedMarkup = preservedMeasureMarkup(in: node)

        let measure = Measure(
            voices: voices,
            startRepeat: startRepeat,
            endRepeatCount: endRepeatCount,
            measureRepeatCount: measureRepeatCount,
            markers: markers,
            jumps: jumps,
            lineBreak: lineBreak,
            pageBreak: pageBreak,
            sectionBreak: sectionBreak,
            actualLength: actualLength,
            irregular: irregular,
            preservedMarkup: preservedMarkup,
        )
        return DecodeResult(measure: measure, systemElements: systemElements)
    }

    /// Preserve only `<LayoutBreak>` subtypes the model did not
    /// interpret while keeping their order relative to every other
    /// unconsumed measure child. `preservedMarkup(consuming:)` first
    /// applies the shared never-preserved policy; this filter then
    /// removes the three modeled break subtypes from that ordered
    /// result.
    private static func preservedMeasureMarkup(
        in node: XMLTreeNode,
    ) -> [PreservedXML] {
        node.preservedMarkup(consuming: consumedMeasureChildren)
            .filter { markup in
                guard markup.name == "LayoutBreak" else { return true }
                let subtype = markup.children
                    .first(where: { $0.name == "subtype" })?.text
                return !modeledLayoutBreakSubtypes.contains(subtype ?? "")
            }
    }

    /// True when this measure carries MS2-style multi-voice content —
    /// at least one Chord / Rest has a `<track>` child whose voice
    /// component (`track mod 4`) is non-zero.
    private static func hasMS2NonZeroVoiceContent(_ node: XMLTreeNode) -> Bool {
        for child in node.children where child.name == "Chord" || child.name == "Rest" {
            if let trackText = child.first("track")?.text,
               let track = Int(trackText),
               track % 4 != 0
            {
                return true
            }
        }
        return false
    }

    /// Bucket the children of an MS2 flat-form `<Measure>` by voice
    /// index (`<track>N</track> mod 4`, defaulting to 0), then decode
    /// each bucket as its own voice. Measure-level metadata
    /// (`<tick>`, `<LayoutBreak>`, `<Marker>`, `<Jump>`, repeat
    /// markers, …) is excluded from the buckets — it's read off the
    /// measure node directly by the caller. `<tick>X</tick>` resets
    /// MuseScore's score-wide cursor between voice groups; for our
    /// per-voice decode it would be a no-op, so we drop it.
    private static func decodeMS2FlatVoices(
        measure node: XMLTreeNode,
    ) throws -> [Voice.DecodeResult] {
        var buckets: [Int: [XMLTreeNode]] = [:]
        for child in node.children {
            switch child.name {
            case "tick", "voice", "LayoutBreak", "Marker", "Jump",
                 "startRepeat", "endRepeat", "irregular",
                 "multiMeasureRest", "measureRepeatCount",
                 "stretch", "noOffset":
                continue
            default:
                break
            }
            let voiceIndex: Int = {
                if let trackText = child.first("track")?.text,
                   let track = Int(trackText)
                {
                    return track % 4
                }
                return 0
            }()
            buckets[voiceIndex, default: []].append(child)
        }
        let sortedIndices = buckets.keys.sorted()
        return try sortedIndices.map { idx in
            let synthetic = XMLTreeNode(
                name: "voice",
                children: buckets[idx] ?? [],
            )
            return try Voice.decodeWithSystemElements(synthetic)
        }
    }

    private static func decodeMarker(_ node: XMLTreeNode) -> Marker {
        let markerType = node.first("markerType")?.text ?? ""
        let kind = Marker.Kind(rawValue: markerType) ?? .other
        let rawLabel = node.first("label")?.text ?? ""
        let text = node.first("text")?.text ?? ""
        return Marker(
            kind: kind,
            // MuseScore instantiates markers with the type's default
            // label (markerTypeTable, marker.cpp:51-62); a file that
            // omits `<label>` still targets jumps by that default.
            label: rawLabel.isEmpty ? kind.defaultLabel : rawLabel,
            text: text,
            preservedMarkup: node.preservedMarkup(consuming: consumedMarkerChildren),
        )
    }

    private static func decodeJump(_ node: XMLTreeNode) -> Jump {
        Jump(
            jumpTo: node.first("jumpTo")?.text ?? "",
            playUntil: node.first("playUntil")?.text ?? "",
            continueAt: node.first("continueAt")?.text ?? "",
            playRepeats: node.first("playRepeats")?.text == "1",
            text: node.first("text")?.text ?? "",
            preservedMarkup: node.preservedMarkup(consuming: consumedJumpChildren),
        )
    }
}
