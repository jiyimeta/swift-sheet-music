import SheetMusicFoundation
#if canImport(os)
    import os
#endif
import SheetMusicCore
import SheetMusicXMLTools

#if canImport(os)
    let mscxDecoderLogger = Logger(
        subsystem: "swift-sheet-music.SheetMusicMSCX",
        category: "MSCXDecoder",
    )
#endif

extension Score {
    /// Every `<Score>` child this decoder reads. Anything else becomes
    /// preserved markup — see `PreservedXML`.
    ///
    /// `<SpannerMap>` is deliberately absent. The version guard only
    /// checks whether it exists; no decoder reads its contents, so it
    /// remains source markup worth preserving for admitted files.
    private static let consumedScoreChildren: Set = [
        "Division", "Part", "Staff", "Style", "metaTag", "programVersion",
    ]

    /// Decode one `.mscx` document.
    ///
    /// `styleFileStyle` is the `<Style>` element of a sibling
    /// `score_style.mss` when the score arrived inside a `.mscz`
    /// container that ships one. MuseScore reads that file into
    /// `MStyle` *before* the score body and lets the score's own
    /// inline `<Style>` override it tag by tag
    /// (`rw/mscloader.cpp:88-97`); passing it here reproduces that
    /// layering. Plain `.mscx` input has no style file and passes nil.
    static func decode(
        _ root: XMLTreeNode, styleFileStyle: XMLTreeNode? = nil,
    ) throws -> Score {
        guard root.name == "museScore" else {
            throw SheetMusicError.malformedScore(
                ScoreFault(
                    code: "mscx.root.wrongElement",
                    message: "root is <\(root.name)>, expected <museScore>",
                    location: root.name,
                ),
            )
        }
        try rejectPreMuseScore2(root: root)
        guard let scoreNode = root.first("Score") else {
            throw SheetMusicError.malformedScore(ScoreFault(
                code: "mscx.score.missing",
                message: "missing <Score>",
                location: "Score",
            ))
        }
        guard let divisionText = scoreNode.first("Division")?.text,
              let division = Int(divisionText)
        else {
            throw SheetMusicError.malformedScore(ScoreFault(
                code: "mscx.division.missing",
                message: "missing <Division>",
                location: "Division",
            ))
        }
        try guardPostMuseScore4(root: root, scoreNode: scoreNode)
        // Resolved up front and published as a TaskLocal: element
        // decoders nested arbitrarily deep need it to tell "absent
        // because default" apart across wire-format generations.
        let version = detectVersion(root: root, scoreNode: scoreNode)
        return try MSCXParserContext.$version.withValue(version) {
            try decodeBody(
                scoreNode: scoreNode,
                division: division,
                version: version,
                styleFileStyle: styleFileStyle,
            )
        }
    }

    private static func decodeBody(
        scoreNode: XMLTreeNode,
        division: Int,
        version: MSCXVersion,
        styleFileStyle: XMLTreeNode?,
    ) throws -> Score {
        let partPairings = try scoreNode.all("Part").enumerated().map {
            try Part.decodePairing($0.element, fallbackIndex: $0.offset + 1)
        }
        let topLevelStaves = try scoreNode.all("Staff").map {
            try MSCXTopLevelStaff.decode($0)
        }
        let assembled = try assembleParts(
            decoded: partPairings, topLevel: topLevelStaves,
        )
        let parts = concertKeysResolved(
            assembled.parts,
            version: version,
            storesConcertPitch: storesConcertPitch(
                scoreNode: scoreNode, styleFileStyle: styleFileStyle,
            ),
        )
        let systemMeasures = assembled.systemMeasures

        var metaTags: [String: String] = [:]
        for tag in scoreNode.all("metaTag") {
            if let name = tag.attributes["name"] {
                metaTags[name] = tag.text
            }
        }

        // VBox under the first top-level Staff (= first Part's first Staff).
        var titleFrame: ScoreFrame?
        if let firstStaff = scoreNode.first("Staff") {
            for child in firstStaff.children {
                if child.name == "VBox" {
                    titleFrame = ScoreFrame.decode(vbox: child)
                    break
                }
                if child.name == "Measure" { break }
            }
        }

        // The container's `score_style.mss` (when present) is the base
        // the score's own `<Style>` overrides — MuseScore reads them in
        // that order. MuseScore 4 writes one or the other, never both,
        // so in practice each side alone decides the style; the
        // layering is what keeps a hand-assembled container correct.
        let base = styleFileStyle
            .map { ScoreStyle.decode(style: $0) } ?? .museScoreDefaults
        let style: ScoreStyle
        if let styleNode = scoreNode.first("Style") {
            style = ScoreStyle.decode(style: styleNode, base: base)
        } else {
            style = base
        }
        let resolvedSystemMeasures = version == .v2
            ? promoteMS2StaffTextSwingToSystem(systemMeasures)
            : systemMeasures
        return Score(
            division: division,
            parts: parts,
            systemMeasures: resolvedSystemMeasures,
            metaTags: metaTags,
            titleFrame: titleFrame,
            style: style,
            source: .museScore(version),
            preservedMarkup: scoreNode.preservedMarkup(consuming: consumedScoreChildren),
        )
    }

    /// `<Style><concertPitch>` — true when the file was saved with Concert Pitch switched on.
    ///
    /// MuseScore's default is off, so an absent element means "written pitch", matching
    /// `MStyle`'s own default. `ScoreStyle` does not model the flag (it is a view mode, not
    /// engraving state), so it is read straight off the node here — from the score's inline
    /// `<Style>` first, then from the container's `score_style.mss`, mirroring the order
    /// MuseScore reads them in.
    private static func storesConcertPitch(
        scoreNode: XMLTreeNode, styleFileStyle: XMLTreeNode?,
    ) -> Bool {
        let text = scoreNode.first("Style")?.first("concertPitch")?.text
            ?? styleFileStyle?.first("concertPitch")?.text
        guard let text else { return false }
        return Int(text) == 1
    }

    /// Convert every key signature of a transposing part from the WRITTEN key back to the concert
    /// one, for files old enough to store only the written form.
    ///
    /// MuseScore 4 writes `<concertKey>` next to `<actualKey>`, and `KeySignature.decode` prefers
    /// `<concertKey>`, so a v4 file already yields concert keys and is returned untouched.
    /// MuseScore 3 and earlier wrote `<accidental>` alone — which the decoder has to shift back by
    /// the instrument's `writtenFifthsOffset`. The instrument is only paired with its staves once
    /// parts are assembled, which is why this is a post-pass rather than something
    /// `KeySignature.decode` could do on its own.
    ///
    /// `storesConcertPitch` gates the whole conversion, mirroring MuseScore's own ≤4.0 reader
    /// (`rw/read400/tread.cpp:1228`, `if (!score->style().styleB(Sid::concertPitch))`): a v2/v3
    /// file saved with Concert Pitch ON already stores `<accidental>` as the CONCERT key, so
    /// subtracting the offset from it would corrupt the import.
    ///
    /// Enharmonic respelling makes this lossy at the edges by nature: a written B♭ major on an
    /// alto sax reads back as concert D♭ major even if the file was written from C♯ major. Both
    /// spell the same pitches, and MuseScore's own round-trip collapses them the same way.
    private static func concertKeysResolved(
        _ parts: [Part], version: MSCXVersion, storesConcertPitch: Bool,
    ) -> [Part] {
        guard version == .v2 || version == .v3, !storesConcertPitch else { return parts }
        return parts.map { part in
            let offset = part.instrument.writtenFifthsOffset
            guard offset != 0 else { return part }
            var part = part
            for staffIndex in part.staves.indices {
                for measureIndex in part.staves[staffIndex].measures.indices {
                    for voiceIndex in part.staves[staffIndex].measures[measureIndex].voices.indices {
                        rewriteKeys(
                            in: &part.staves[staffIndex].measures[measureIndex]
                                .voices[voiceIndex].elements,
                            offset: offset,
                        )
                    }
                }
            }
            return part
        }
    }

    private static func rewriteKeys(in elements: inout [VoiceElement], offset: Int) {
        for index in elements.indices {
            guard case var .keySignature(key) = elements[index] else { continue }
            key.concertKey = respelledKey(key.concertKey - offset)
            elements[index] = .keySignature(key)
        }
    }

    /// MuseScore 2 wrote swing markers inside `<StaffText>` even when
    /// the user intended a score-wide directive — MuseScore 2's UI had
    /// no separate SystemText path for swing, and the playback engine
    /// fanned every swing tag out across all staves. MuseScore 3's
    /// MS2 import path mirrors that intent by promoting the tag to
    /// `<SystemText>` on save (visible by re-saving an MS2 `.mscz` in
    /// 3.6.2). Replicate the promotion so the renderer's per-staff
    /// swing routing (`MidiRenderer+Swing`) doesn't restrict the
    /// effect to the originating staff and silently drop swing on
    /// drums / bass / etc.
    private static func promoteMS2StaffTextSwingToSystem(
        _ measures: [SystemMeasure],
    ) -> [SystemMeasure] {
        measures.map { measure in
            let elements = measure.elements.map { positioned -> PositionedSystemElement in
                guard case let .swing(swing) = positioned.element,
                      !swing.isSystemText
                else {
                    return positioned
                }
                var promoted = swing
                promoted.isSystemText = true
                return PositionedSystemElement(
                    position: positioned.position,
                    element: .swing(promoted),
                    originalStaff: positioned.originalStaff,
                )
            }
            return SystemMeasure(elements: elements)
        }
    }

    /// Detect MuseScore wire-format major version from the
    /// `<museScore version="…">` attribute. Falls back to `<programVersion>`
    /// (used by 3.x exports) and finally defaults to `.v4` when no
    /// recognizable marker is present.
    ///
    /// `version="2.x"` is reported as `.v2` so `ScoreSource` can
    /// surface a "MuseScore 2" badge. A warning is logged because the
    /// decoder itself is MS3/MS4-shaped — MS2 files are parsed
    /// best-effort and the resulting `Score` may be incomplete.
    /// MuseScore 1 keeps the score's children directly under
    /// `<museScore>` — there is no `<Score>` element to find — so the
    /// reader's first structural check fails and reports a missing
    /// `<Score>`, which describes the symptom and hides the cause. Say
    /// which generation the file is instead: these are still in the
    /// wild (the corpus has one saved in 2015), and the answer for a
    /// caller is to re-save it from MuseScore, not to go looking for a
    /// damaged file.
    ///
    /// MuseScore 2 is deliberately not rejected here — it is
    /// `<Score>`-shaped and `detectVersion` parses it leniently with a
    /// warning.
    private static func rejectPreMuseScore2(root: XMLTreeNode) throws {
        guard let versionAttr = root.attributes["version"],
              let major = versionAttr.split(separator: ".").first,
              let majorInt = Int(major), majorInt <= 1
        else { return }
        throw SheetMusicError.malformedScore(ScoreFault(
            code: "mscx.version.unsupported",
            message: """
            MuseScore \(majorInt) file (museScore version="\(versionAttr)"); \
            this reader supports MuseScore 3 and 4 shapes, and parses \
            MuseScore 2 leniently — re-save the file from MuseScore to open it
            """,
            location: "museScore",
        ))
    }

    /// Guard a wire format newer than the MuseScore 4 shapes this
    /// reader implements. Refuses only what it knows it would get
    /// wrong; everything else is admitted with a diagnostic.
    ///
    /// `detectVersion` folds every major >= 4 into `.v4`, so without
    /// this a MuseScore 5 file parses "successfully" no matter what it
    /// contains. The one MSC 5.00 change that is catastrophic rather
    /// than lossy is `<Score><SpannerMap>`: MuseScore 5 moved every
    /// spanner in `Score::spannerMap()` out of the inline `<Spanner>` +
    /// `<location>` form into that node, with endpoints written as EID
    /// references (`rw/write/twrite.cpp:writeScoreSpanners`, reached
    /// from `rw/write/writer.cpp`; `<startElement>` / `<endElement>` in
    /// `TWrite::writeProperties(const Spanner*)`). This decoder never
    /// visits it, so slurs, hairpins, ottavas, voltas and pedals would
    /// all vanish — taking repeat structure, and therefore MIDI output,
    /// with them. Silence is the wrong answer to that, so it throws.
    ///
    /// A MuseScore 5 file *without* that node is a different case. The
    /// writer emits `<SpannerMap>` only when the score has spanners, so
    /// a spanner-free 5.00 score is still within what the 4.x-shaped
    /// reader handles — the MusicXML reference corpus under
    /// `Tests/SheetMusicTests/Resources/musicxml/` is exactly that, and
    /// refusing it would reject files this package reads correctly
    /// today. Those get a warning instead, per the permissive parser
    /// policy in `AGENTS.md`: unaudited 5.00 deltas may still be
    /// dropped, and the diagnostic is how a host learns to distrust the
    /// result.
    ///
    /// The fault reuses `malformedScore` so hosts that already branch
    /// on it keep working, but carries its own `code`: the advice
    /// differs from `mscx.version.unsupported`. A MuseScore 1 file is
    /// the reader's user's problem to fix (re-save it); a MuseScore 5
    /// file is this package's problem to fix (ship support). See
    /// `docs/musescore-model-parity.md` §3.
    private static func guardPostMuseScore4(root: XMLTreeNode, scoreNode: XMLTreeNode) throws {
        guard let versionAttr = root.attributes["version"],
              let major = versionAttr.split(separator: ".").first,
              let majorInt = Int(major), majorInt >= 5
        else { return }
        // Bound to a local rather than tested inline: SwiftLint reads
        // `first(…) == nil` as the `first(where:)` overload and asks for
        // `contains`, which `XMLTreeNode`'s name-keyed lookup is not.
        let spannerMap = scoreNode.first("SpannerMap")
        guard spannerMap == nil else {
            throw SheetMusicError.malformedScore(ScoreFault(
                code: "mscx.version.tooNew",
                message: """
                MuseScore \(majorInt) file (museScore version="\(versionAttr)") \
                with a <SpannerMap>; this reader implements the MuseScore 3 and 4 \
                wire formats, where spanners are written inline, and would drop \
                every slur, hairpin, ottava, volta and pedal in the score — \
                export it as MusicXML, or save it from MuseScore 4, to open it here
                """,
                location: "museScore",
            ))
        }
        mscxDecoderWarn(
            code: "mscx.version.newerThanSupported",
            message: """
            MuseScore \(majorInt) file (museScore version="\(versionAttr)"); \
            this reader implements the MuseScore 3 and 4 wire formats. It has no \
            <SpannerMap>, so it is being parsed through the MuseScore 4 reader — \
            elements introduced or moved in MuseScore \(majorInt) may be dropped \
            silently.
            """,
            location: "museScore",
        )
    }

    private static func detectVersion(
        root: XMLTreeNode, scoreNode: XMLTreeNode,
    ) -> MSCXVersion {
        if let versionAttr = root.attributes["version"],
           let major = versionAttr.split(separator: ".").first,
           let majorInt = Int(major)
        {
            if majorInt <= 2 {
                let programVersion = scoreNode.first("programVersion")?.text ?? "unknown"
                mscxDecoderWarn(
                    code: "mscx.score.museScoreVersion2",
                    message: """
                    detected MuseScore 2 file (museScore version=\"\(versionAttr)\", \
                    programVersion=\(programVersion)); parsing through the MS3/MS4-shaped \
                    reader — some MS2-only fields will be skipped silently.
                    """,
                )
                return .v2
            }
            return majorInt == 3 ? .v3 : .v4
        }
        if let programVersion = scoreNode.first("programVersion")?.text {
            if programVersion.hasPrefix("2.") {
                mscxDecoderWarn(
                    code: "mscx.score.museScoreVersion2",
                    message: """
                    detected MuseScore 2 file via programVersion \(programVersion); \
                    parsing through the MS3/MS4-shaped reader — some MS2-only fields \
                    will be skipped silently.
                    """,
                )
                return .v2
            }
            if programVersion.hasPrefix("3.") {
                return .v3
            }
        }
        return .v4
    }
}
