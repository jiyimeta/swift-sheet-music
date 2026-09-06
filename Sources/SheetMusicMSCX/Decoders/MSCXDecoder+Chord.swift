import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Chord {
    /// Every direct `<Chord>` child this decoder reads, including
    /// children interpreted by the voice decoder before this method
    /// is called. Anything else becomes preserved markup.
    private static let consumedChordChildren: Set = [
        "Arpeggio", "Articulation", "ChordBracket", "ChordLine", "Lyrics",
        "Note", "NoteParenGroup", "Ornament", "Spanner", "Stem", "Tremolo",
        "TremoloSingleChord", "TremoloTwoChord", "acciaccatura",
        "appoggiatura", "color", "dots", "durationType", "grace16",
        "grace16after", "grace32", "grace32after", "grace4", "grace8after",
        "offset", "placement", "small", "track", "visible",
    ]

    static func decode(_ node: XMLTreeNode) throws -> Chord {
        guard
            let durationText = node.first("durationType")?.text,
            let baseDuration = NoteDuration(mscxName: durationText)
        else {
            throw SheetMusicError.malformedScore(ScoreFault(
                code: "mscx.chord.invalidDurationType",
                message: "Chord missing/invalid <durationType>",
                location: "Chord",
            ))
        }
        let dots = Int(node.first("dots")?.text ?? "0") ?? 0
        let duration = baseDuration.dotted(dots)
        var notes = try decodeNotes(node)
        applyNoteParenGroup(node, to: &notes)

        var arpeggio: Arpeggio?
        if let arpeggioNode = node.first("Arpeggio") {
            let subtype = Int(arpeggioNode.first("subtype")?.text ?? "0") ?? 0
            let stretch = Double(arpeggioNode.first("timeStretch")?.text ?? "1") ?? 1.0
            let userLen = Double(arpeggioNode.first("userLen1")?.text ?? "0") ?? 0.0
            arpeggio = Arpeggio(subtype: subtype, timeStretch: stretch, userLen1: userLen)
            arpeggio?.elementProperties = ElementProperties(decodingMSCXChildrenOf: arpeggioNode)
        }

        let articulations = node.all("Articulation").map { artNode -> ChordArticulation in
            let subtype = artNode.first("subtype")?.text ?? ""
            return ChordArticulation.fromSubtypeXML(subtype)
        }

        // MS3 emits `<Tremolo>`; MS4 split it into `<TremoloSingleChord>`
        // and `<TremoloTwoChord>`. Accept any of the three — MuseScore
        // only ever writes one per chord, so first-match wins.
        let tremoloNode = node.first("Tremolo")
            ?? node.first("TremoloSingleChord")
            ?? node.first("TremoloTwoChord")
        let tremolo = tremoloNode.flatMap(Tremolo.decode)

        // `<Stem>` element inside `<Chord>` carries per-stem properties
        // (e.g. `<userLen>`, `<visible>`). We currently honor only
        // `<visible>` — when 0 the stem (and flag) are hidden while the
        // noteheads stay visible. Default is visible.
        var stemVisible = true
        if let stemNode = node.first("Stem") {
            stemVisible = (stemNode.first("visible")?.text ?? "1") != "0"
        }

        var chord = Chord(
            duration: duration, notes: ChordNotes(notes),
            arpeggio: arpeggio, bracket: ChordBracket.decode(inChord: node),
            lyrics: decodeLyrics(node),
            articulations: articulations,
            ornaments: ChordOrnament.decodeAll(inChord: node),
            tremolo: tremolo,
            chordLines: ChordLine.decodeAll(inChord: node),
            stemVisible: stemVisible,
            preservedMarkup: node.preservedMarkup(consuming: consumedChordChildren),
        )
        chord.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        chord.spanners = decodeChordSpanners(node)
        return chord
    }

    /// `<Slur>` payload children this decoder either models or knowingly
    /// elides. Everything else is unmodeled and reported by
    /// `mscx.slur.propertiesDropped`.
    ///
    /// `placement`, `visible` and `beginText` are MODELED, not elided:
    /// `Spanner.decode` reads the payload's `ElementProperties`, applies
    /// `decodeVisible` and `decodeBeginText`, and lands all three on `Spanner`.
    /// Warning on them would report a loss that does not happen.
    ///
    /// The rest are the allowlist:
    ///
    /// - `eid` — MuseScore 4.6's regenerated internal element id. No decoder
    ///   in this package models it anywhere, it carries no user data (4.6
    ///   mints a fresh one on every save), and warning on it would fire on
    ///   every element of every 4.6 score. Same reasoning, same silence, as
    ///   `Note.eidChildName` in `MSCXDecoder+GuitarBend.swift`.
    /// - `linkedMain` / `linked` — part-linking bookkeeping. MuseScore tags
    ///   the master copy of a linked element `<linkedMain/>` and every linked
    ///   copy `<linked>…</linked>` (4.2 `TWrite::writeProperties(const
    ///   EngravingItem*, …)`, `rw/write/twrite.cpp:307` and `:314`; 3.6.2
    ///   `Element::writeProperties`, `libmscore/element.cpp:602`). The writer
    ///   recomputes both from the score's link structure rather than reading
    ///   them back off the element, and they appear on *every* element of
    ///   *every* score that has parts or a linked tablature staff — the
    ///   vendored `slur_ms4_glissando_legato.mscx` carries one inside the
    ///   `<Slur>` of both its begin sides, and they are the only payload
    ///   children it has. Announcing them would bury the diagnostics that
    ///   report real data loss.
    private static let slurKnownChildren: Set = [
        "placement",
        "visible",
        "beginText",
        "eid",
        "linkedMain",
        "linked",
    ]

    /// Chord-anchored `<Spanner>` children. MuseScore writes slurs ONLY
    /// here — begin side (payload + `<next>`) inside the start chord/rest, a
    /// `<prev>`-only marker inside the end one. Its `ChordRest` writer walks
    /// the spanner map and skips everything that is not a slur outright
    /// (`if (s->generated() || !s->isSlur() || …) continue;` —
    /// `TWrite::writeProperties(const ChordRest*, …)`,
    /// `rw/write/twrite.cpp:1093`, the loop at `:1135`), which is why any
    /// other type found here is announced rather than decoded.
    ///
    /// The `<prev>` side carries no model state — the encoder recomputes it
    /// from the begin side's `<next>` — so only begin sides are returned.
    ///
    /// `XMLTreeNode.all` matches direct children only, so the note-anchored
    /// spanners (glissando, guitar bend, tie) that live inside `<Note>` are
    /// not seen here.
    static func decodeChordSpanners(_ node: XMLTreeNode) -> [Spanner] {
        var result: [Spanner] = []
        for spannerNode in node.all("Spanner") {
            let rawType = spannerNode.attributes["type"] ?? ""
            guard rawType == Spanner.Kind.slur.rawValue else {
                mscxDecoderWarn(
                    code: "mscx.chord.spannerDropped",
                    message: "Chord-level <Spanner type=\"\(rawType)\"> is not modeled — dropped",
                    location: "Chord/Spanner",
                )
                continue
            }
            guard spannerNode.children.contains(where: { $0.name == "next" }) else {
                // A `<prev>`-only element is the end marker of a pair whose
                // begin side lives on an earlier chord: nothing to keep, and
                // nothing lost. Neither side present is a shape MuseScore
                // never writes — it can be neither placed nor discarded.
                if !spannerNode.children.contains(where: { $0.name == "prev" }) {
                    mscxDecoderWarn(
                        code: "mscx.chord.spannerDropped",
                        message: "Chord-level <Spanner type=\"Slur\"> missing <next>/<prev> — dropped",
                        location: "Chord/Spanner",
                    )
                }
                continue
            }
            warnDroppedSlurProperties(spannerNode)
            warnDroppedSlurLocation(spannerNode)
            if let spanner = try? Spanner.decode(spannerNode) {
                result.append(spanner)
            }
        }
        return result
    }

    /// Announce, in one diagnostic per slur, every `<Slur>` payload child
    /// outside `slurKnownChildren` — tags sorted and deduped.
    ///
    /// The realistic strays are the slur's own shape and style properties
    /// (`up` for the forced arc side, `lineType` for solid / dotted / dashed,
    /// `SlurSegment` for a user-dragged control point) plus the generic item
    /// properties MuseScore writes on any element (`offset`, `color`,
    /// `autoplace`, `track`, …). None of them are modeled, so the loss is
    /// reported rather than passed over.
    ///
    /// A slur with no `<Slur>` payload child at all loses nothing and is
    /// silent.
    private static func warnDroppedSlurProperties(_ spannerNode: XMLTreeNode) {
        guard let slurNode = spannerNode.first("Slur") else { return }
        let dropped = Set(slurNode.children.map(\.name))
            .subtracting(slurKnownChildren)
            .sorted()
        guard !dropped.isEmpty else { return }
        mscxDecoderWarn(
            code: "mscx.slur.propertiesDropped",
            message: "<Slur> children not modeled and dropped: "
                + dropped.joined(separator: ", "),
            location: "Chord/Spanner[Slur]",
        )
    }

    /// `<next><location>` children `Spanner.decode` actually reads. MuseScore's
    /// `Location` carries six fields and one writer emits them all —
    /// `staves, voices, measures, fractions, grace, notes` (3.6.2
    /// `Location::write`, `libmscore/location.cpp:52-63`; master
    /// `TWrite::write(const Location*, …)`, `rw/write/twrite.cpp:2229-2243`,
    /// which adds `timeTick`). This model holds two of them.
    private static let slurKnownLocationChildren: Set = [
        "measures",
        "fractions",
    ]

    /// Announce, in one diagnostic per slur, every `<next><location>` child
    /// the model cannot hold — tags sorted and deduped.
    ///
    /// The one that really occurs is `<voices>`: a slur whose two ends live in
    /// different voices writes the voice delta there, and
    /// `slur_ms3_exchangevoices.mscx:221-230` is exactly that. Dropping it
    /// moves the slur's end — the encoder can only re-home the `<prev>` within
    /// the begin side's own voice — so it is real data loss and must be said
    /// out loud rather than passed over. `<staves>` (cross-staff slur),
    /// `<grace>`, `<notes>` and `<timeTick>` are the same story, less common.
    ///
    /// This deliberately does *not* touch `Spanner.decode`: voice-level
    /// spanners share that reader and are out of scope here.
    private static func warnDroppedSlurLocation(_ spannerNode: XMLTreeNode) {
        guard let location = spannerNode.first("next")?.first("location")
        else { return }
        let dropped = Set(location.children.map(\.name))
            .subtracting(slurKnownLocationChildren)
            .sorted()
        guard !dropped.isEmpty else { return }
        mscxDecoderWarn(
            code: "mscx.slur.locationDropped",
            message: "<Slur> <next><location> children not modeled and dropped: "
                + dropped.joined(separator: ", "),
            location: "Chord/Spanner[Slur]",
        )
    }

    /// Decode the `<Lyrics>` children of a `<Chord>` node — one per
    /// verse line. Verse number comes from `<no>` (0-indexed); absent =
    /// verse 0. `<syllabic>` places the syllable in a hyphenated word;
    /// `<ticks>` sizes melismas.
    ///
    /// Gaps in the verse numbering are padded with empty placeholders so
    /// the returned array is indexable by verse; the encoder skips those
    /// again on write.
    private static func decodeLyrics(_ node: XMLTreeNode) -> [Lyric] {
        var lyricsMap: [Int: Lyric] = [:]
        for lyricsNode in node.all("Lyrics") {
            let verse = Int(lyricsNode.first("no")?.text ?? "0") ?? 0
            let text = lyricsNode.first("text")?.text ?? ""
            let syllabic = (lyricsNode.first("syllabic")?.text)
                .flatMap(Syllabic.init(mscxValue:)) ?? .single
            let ticks = Int(lyricsNode.first("ticks")?.text ?? "0") ?? 0
            var lyric = Lyric(
                text: text, syllabic: syllabic, ticks: ticks,
                verse: verse,
                properties: TextProperties.decode(lyricsNode),
                preservedMarkup: lyricsNode.preservedMarkup(
                    consuming: consumedLyricsChildren,
                ),
            )
            lyric.elementProperties = ElementProperties(decodingMSCXChildrenOf: lyricsNode)
            lyricsMap[verse] = lyric
        }
        let maxVerse = lyricsMap.keys.max() ?? -1
        guard maxVerse >= 0 else { return [] }
        return (0 ... maxVerse).map { i in
            lyricsMap[i] ?? Lyric(text: "", verse: i)
        }
    }

    /// Every direct `<Lyrics>` child read by `decodeLyrics`,
    /// `TextProperties.decode`, or `ElementProperties`.
    private static let consumedLyricsChildren: Set = [
        "bold", "color", "face", "framePadding", "frameType", "italic",
        "no", "offset", "placement", "size", "strike", "syllabic", "text", "ticks", "underline",
        "visible",
    ]

    /// Decode the `<Note>` children of a `<Chord>` node, propagating
    /// chord-level `<small>1</small>` to every note that isn't already
    /// small. MuseScore writes `<small>` on the chord element when the
    /// whole chord is displayed at a reduced size (cue / small noteheads).
    private static func decodeNotes(_ node: XMLTreeNode) throws -> [Note] {
        let rawNotes = try node.all("Note").map { try Note.decode($0) }
        guard node.first("small")?.text == "1" else { return rawNotes }
        return rawNotes.map { n in
            guard !n.isSmall else { return n }
            var copy = n; copy.isSmall = true; return copy
        }
    }

    /// Apply a MuseScore 4.7+ chord-level `<NoteParenGroup>` to the chord's
    /// decoded notes. The group binds parentheses to notes by 0-based
    /// `<NoteIdx>` into the chord's note list. MuseScore synthesizes both
    /// sides on read, so a referenced note is always `.both`. Out-of-range
    /// indices are skipped (permissive parser).
    private static func applyNoteParenGroup(_ node: XMLTreeNode, to notes: inout [Note]) {
        guard let group = node.first("NoteParenGroup"),
              let notesNode = group.first("Notes")
        else { return }
        for idxNode in notesNode.all("NoteIdx") {
            guard let idx = Int(idxNode.text), notes.indices.contains(idx) else { continue }
            notes[idx].parentheses = .both
        }
    }

    /// Inspect a `<Chord>` node and return its grace category if any
    /// of the 8 grace child-tags is present. nil = ordinary chord.
    /// C++: `MeasureRead::readChord` sets `_noteType` from these tags
    /// (`engraving/dom/measure/measureread.cpp`).
    static func graceType(in node: XMLTreeNode) -> GraceType? {
        for child in node.children {
            if let g = GraceType(mscxTag: child.name) { return g }
        }
        return nil
    }
}

extension ChordArticulation {
    /// Map an MS4 SymId-style `<subtype>` string to a ChordArticulation.
    /// Unknown / empty values fall through to `.unknown(...)` with
    /// `anchor == nil` so the original string round-trips verbatim.
    static func fromSubtypeXML(_ subtype: String) -> ChordArticulation {
        let anchor: ChordArticulation.Anchor?
        let base: String
        if subtype.hasSuffix("Above") {
            anchor = .above
            base = String(subtype.dropLast("Above".count))
        } else if subtype.hasSuffix("Below") {
            anchor = .below
            base = String(subtype.dropLast("Below".count))
        } else {
            anchor = nil
            base = subtype
        }
        guard let kind = ChordArticulation.Kind(mscxToken: base) else {
            return .init(kind: .unknown(subtype: subtype))
        }
        return .init(kind: kind, anchor: anchor)
    }
}
