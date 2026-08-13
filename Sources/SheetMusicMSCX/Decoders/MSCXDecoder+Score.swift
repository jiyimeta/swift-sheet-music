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
    static func decode(_ root: XMLTreeNode) throws -> Score {
        guard root.name == "museScore" else {
            throw SheetMusicError.malformedScore(
                reason:
                "root is <\(root.name)>, expected <museScore>",
            )
        }
        guard let scoreNode = root.first("Score") else {
            throw SheetMusicError.malformedScore(reason: "missing <Score>")
        }
        guard let divisionText = scoreNode.first("Division")?.text,
              let division = Int(divisionText)
        else {
            throw SheetMusicError.malformedScore(reason: "missing <Division>")
        }
        // Resolved up front and published as a TaskLocal: element
        // decoders nested arbitrarily deep need it to tell "absent
        // because default" apart across wire-format generations.
        let version = detectVersion(root: root, scoreNode: scoreNode)
        return try MSCXParserContext.$version.withValue(version) {
            try decodeBody(scoreNode: scoreNode, division: division, version: version)
        }
    }

    private static func decodeBody(
        scoreNode: XMLTreeNode, division: Int, version: MSCXVersion,
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
        let parts = assembled.parts
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

        let style: ScoreStyle
        if let styleNode = scoreNode.first("Style") {
            style = ScoreStyle.decode(style: styleNode)
        } else {
            style = .museScoreDefaults
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
        )
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
