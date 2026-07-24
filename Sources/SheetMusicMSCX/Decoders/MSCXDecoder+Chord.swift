import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Chord {
    static func decode(_ node: XMLTreeNode) throws -> Chord {
        guard
            let durationText = node.first("durationType")?.text,
            let baseDuration = NoteDuration(mscxName: durationText)
        else {
            throw SheetMusicError.malformedScore(reason: "Chord missing/invalid <durationType>")
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
            arpeggio: arpeggio, lyrics: decodeLyrics(node),
            articulations: articulations,
            tremolo: tremolo,
            chordLines: ChordLine.decodeAll(inChord: node),
            stemVisible: stemVisible,
        )
        chord.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return chord
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
        switch base {
        case "articStaccato": return .init(kind: .staccato, anchor: anchor)
        case "articStaccatissimo": return .init(kind: .staccatissimo, anchor: anchor)
        case "articTenuto": return .init(kind: .tenuto, anchor: anchor)
        case "articAccent": return .init(kind: .accent, anchor: anchor)
        case "articMarcato": return .init(kind: .marcato, anchor: anchor)
        case "articAccentStaccato": return .init(kind: .accentStaccato, anchor: anchor)
        case "articMarcatoStaccato": return .init(kind: .marcatoStaccato, anchor: anchor)
        default: return .init(kind: .unknown(subtype: subtype))
        }
    }
}
