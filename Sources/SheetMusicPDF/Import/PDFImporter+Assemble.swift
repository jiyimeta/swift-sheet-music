// swiftlint:disable file_length
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

extension PDFImporter {
    /// Stage [12+] — assemble a `Score` from the per-page `ImportSystem`
    /// list plus the page-level text and classified-glyph streams.
    ///
    /// MVP scope (Task 13): part shape + linear measures with running
    /// clef/key/time, voice assignment, lyric attachment, and title
    /// frame. Structure detection (markers/jumps/voltas/rehearsals/
    /// barline subtypes) and tempo events are deferred — Task 15
    /// round-trip work will surface those in the final Score.
    static func assembleScore(
        firstPageSize: CGSize?,
        documentAttributes: [String: Any]?,
        systems: [ImportSystem],
        texts: [TextGlyph],
        classified: [ClassifiedGlyph],
        paths: [PathSegment],
        tieMarks: TieMarks = TieMarks(),
        graceSizeThreshold: CGFloat = 0,
        options: PDFImportOptions,
        geometry: PDFGeometryCollector? = nil,
    ) -> Score {
        guard !systems.isEmpty else {
            return Score(division: 480, source: .pdf)
        }
        // Derive the global part shape from the RICHEST system (max total
        // staves), not blindly from systems[0]. The first system is often a
        // title-page system whose staff detection is degenerate (fewer
        // staves than the body), which would otherwise truncate every later
        // system's surplus staves in `appendSystem`'s zip. The richest
        // system is the best single template for the full ensemble.
        let referenceSystem = systems.max { lhs, rhs in
            totalStaves(lhs) < totalStaves(rhs)
        } ?? systems[0]
        let shape = partShape(from: referenceSystem)
        // Strip the arrangers' colon-prefixed StaffText performance notes
        // ("Lead:…", "Perc.:…") from the text pool up front, so they can't
        // masquerade as lyric syllables in `attachLyrics`. Page-wide, because
        // a typed sentence spans several measures' x-cells. See
        // `removeColonAnnotations`. Uses the reference ensemble's median staff
        // line-spacing as the row-grouping tolerance.
        let texts = removeColonAnnotations(
            texts, lineSpacing: referenceLineSpacing(referenceSystem),
        )
        var stavesContent: [[Measure]] = Array(
            repeating: [], count: shape.totalStaffSlots,
        )
        var state = StaffStateMap()
        let pageBoundaries = systemPageBoundaries(systems)
        // Pre-pass: resolve the ambiguous E065 (F8va) clef once per staff
        // SLOT, using the slot's whole-part note content aggregated across
        // every system, so a low-content system can't flip an octave. Empty
        // for documents with no F8va clef (the common case). See
        // `disambiguateF8vaClef`.
        let f8vaOverrides = resolveF8vaSlots(systems: systems, shape: shape)

        for (sysIndex, system) in systems.enumerated() {
            appendSystem(
                system: system,
                sysIndex: sysIndex,
                isLastInPage: pageBoundaries.contains(sysIndex),
                isLastSystem: sysIndex == systems.count - 1,
                shape: shape,
                texts: texts,
                paths: paths,
                tieMarks: tieMarks,
                graceSizeThreshold: graceSizeThreshold,
                clefOverrides: f8vaOverrides,
                stavesContent: &stavesContent,
                state: &state,
                options: options,
                geometry: geometry,
            )
        }

        // Distribute measure arrays back into each Part's staves (and build
        // the geometry side-car's slot → StaffAddress inverse).
        var assembledParts = shape.parts
        distributeMeasures(
            into: &assembledParts, shape: shape,
            stavesContent: stavesContent, geometry: geometry,
        )
        // Propagate pitch along tie chains: a tied-back note inherits its
        // source note's pitch (incl. any accidental MuseScore did not redraw
        // on the continuation). Conservative + monotonic — only a genuine
        // mismatch is repaired. See PDFImporter+TiePitch.
        propagateTiePitches(parts: &assembledParts)
        // Promote per-measure percussion-clef detection to the part / staff /
        // instrument level so a drum staff reads as a GM drum kit (channel-10
        // playback, drum-line note positioning). No-op for pitched parts.
        markPercussionStaves(&assembledParts)
        let titleFrame = makeTitleFrame(
            firstPageSize: firstPageSize, documentAttributes: documentAttributes,
            texts: texts, options: options,
        )
        // Recover tempo markings ("♩ = NN") from the page text into
        // system measures so playback uses the engraved BPM, not the 120
        // default. Mapped to the measure each marking sits above.
        let systemMeasures = tempoSystemMeasures(
            systems: systems, texts: texts,
            measureCount: assembledParts.first?.staves.first?.measures.count ?? 0,
        )
        return Score(
            division: 480,
            parts: assembledParts,
            systemMeasures: systemMeasures,
            titleFrame: titleFrame,
            source: .pdf,
        )
    }

    /// Distribute each slot's measure array back into its Part's staff, and
    /// (for the geometry side-car) build the slot → StaffAddress inverse —
    /// the only place that mapping is known.
    private static func distributeMeasures(
        into parts: inout [Part],
        shape: PartShape,
        stavesContent: [[Measure]],
        geometry: PDFGeometryCollector?,
    ) {
        var slotToStaff: [Int: StaffAddress] = [:]
        for (partIdx, slots) in shape.slotsByPartIndex {
            for (staffIdx, slot) in slots.enumerated() {
                parts[partIdx].staves[staffIdx].measures = stavesContent[slot]
                slotToStaff[slot] = StaffAddress(
                    partIndex: partIdx, staffIndexInPart: staffIdx,
                )
            }
        }
        geometry?.setSlotToStaff(slotToStaff)
    }

    // MARK: - System append
    //
    // Part-shape derivation (`PartShape`, `partShape(from:)`, `totalStaves`),
    // the per-system part → global-slot mapping (`partSlotMapping`), and the
    // F8va clef pre-pass (`resolveF8vaSlots`) live in
    // PDFImporter+AssembleParts.swift.

    /// Append every staff's measures from one system into the running
    /// `stavesContent`. Updates `state` (per-slot clef/key/time) and
    /// applies break flags when `options.preserveBreaks` is on.
    private static func appendSystem(
        system: ImportSystem,
        sysIndex: Int,
        isLastInPage: Bool,
        isLastSystem: Bool,
        shape: PartShape,
        texts: [TextGlyph],
        paths: [PathSegment],
        tieMarks: TieMarks,
        graceSizeThreshold: CGFloat,
        clefOverrides: [Int: Clef],
        stavesContent: inout [[Measure]],
        state: inout StaffStateMap,
        options: PDFImportOptions,
        geometry: PDFGeometryCollector?,
    ) {
        // One system rect per ImportSystem (its y-range × page width), used
        // to grow a cursor column to full system height and for auto-scroll.
        geometry?.recordSystem(yRange: system.yRange, pageIndex: system.pageIndex)
        // Stems / barlines etc. are page-local; pre-filter to this
        // system's page so a vertical at the same x on another page can't
        // be mistaken for a stem in `decodeRhythm`'s xRange test.
        let pagePaths = paths.filter { $0.pageIndex == system.pageIndex }
        // Top-line y of every staff in this system (PDF y-up: larger y =
        // higher). Used to bound each staff's lyric band by the staff
        // directly below it — a staff's lyrics sit in the gap above the next
        // staff, so that staff's top line is the band floor. See
        // `attachLyrics`.
        let systemStaffTops = system.parts
            .flatMap(\.staves)
            .map { $0.staff.yLines.last ?? -.greatestFiniteMagnitude }
        // Map this system's parts → reference part indices by vertical
        // position. On a full system this is the identity (part i → ref i);
        // on an UNDER-FULL system (fewer parts than the reference ensemble)
        // it routes each present part to the reference slot whose vertical
        // position it matches, so a missing part leaves its slots empty
        // instead of shifting every part up. See `partSlotMapping`.
        let refForSystemPart = partSlotMapping(system: system, shape: shape)
        for (partIdx, importPart) in system.parts.enumerated() {
            let refIdx = refForSystemPart[partIdx]
            guard let slots = shape.slotsByPartIndex[refIdx] else { continue }
            // Defensive: a later system might have extra staves not
            // present in the first system. Ignore the surplus rather
            // than crash.
            let pairs = zip(slots, importPart.staves)
            for (slot, importStaff) in pairs {
                let location = "page \(system.pageIndex), system \(sysIndex)"
                // Nearest staff below this one within the system: the highest
                // top-line among staves whose top is below this staff's bottom
                // line. `nil` for the lowest staff (the lyric band then uses
                // its depth cap alone).
                let thisBottomY = importStaff.staff.yLines.first ?? 0
                let nextStaffTopY = systemStaffTops
                    .filter { $0 < thisBottomY }
                    .max()
                // Global measure index of this system's first measure on
                // this slot = the count already appended. The geometry
                // collector keys on the final (global) measure index.
                let measureIndexOffset = stavesContent[slot].count
                let measures = buildMeasures(
                    importStaff: importStaff,
                    texts: texts,
                    paths: pagePaths,
                    tieMarks: tieMarks,
                    graceSizeThreshold: graceSizeThreshold,
                    clefOverride: clefOverrides[slot],
                    nextStaffTopY: nextStaffTopY,
                    state: &state,
                    slot: slot,
                    measureIndexOffset: measureIndexOffset,
                    location: location,
                    options: options,
                    geometry: geometry,
                )
                stavesContent[slot].append(contentsOf: measures)
                applyBreaks(
                    to: &stavesContent[slot],
                    appended: measures.count,
                    isLastInPage: isLastInPage,
                    isLastSystem: isLastSystem,
                    options: options,
                )
            }
        }
    }

    private static func applyBreaks(
        to measures: inout [Measure],
        appended: Int,
        isLastInPage: Bool,
        isLastSystem: Bool,
        options: PDFImportOptions,
    ) {
        guard options.preserveBreaks, appended > 0, !measures.isEmpty else { return }
        let last = measures.count - 1
        if !isLastSystem {
            measures[last].lineBreak = true
        }
        if isLastInPage, !isLastSystem {
            measures[last].pageBreak = true
        }
    }
}

// MARK: - Measure assembly

extension PDFImporter {
    /// Per-slot running score state. Indexed by the flat staff-slot
    /// index produced by `PartShape`.
    fileprivate struct StaffStateMap {
        var clef: [Int: Clef] = [:]
        var key: [Int: KeySignature] = [:]
        var time: [Int: TimeSignature] = [:]
    }

    /// Rewrite every F8va clef event to the whole-part resolved clef decided
    /// by `resolveF8vaSlots` (see `disambiguateF8vaClef`). A nil override or a
    /// non-F8va clef is left untouched. Extracted from `buildMeasures` to keep
    /// its body within the function-length limit.
    fileprivate static func remapF8vaClef(
        _ events: [ScoreStateEvent], to clefOverride: Clef?,
    ) -> [ScoreStateEvent] {
        guard let clefOverride else { return events }
        return events.map { ev in
            if case let .clefChange(c, mi) = ev, c.concertClefType == "F8va" {
                return .clefChange(clefOverride, atMeasureIndex: mi)
            }
            return ev
        }
    }

    /// Walk `importStaff.measures` left-to-right, applying score-state
    /// events from this staff and producing a `Measure` per cell.
    fileprivate static func buildMeasures(
        importStaff: ImportStaff,
        texts: [TextGlyph],
        paths: [PathSegment],
        tieMarks: TieMarks,
        graceSizeThreshold: CGFloat,
        clefOverride: Clef?,
        nextStaffTopY: CGFloat?,
        state: inout StaffStateMap,
        slot: Int,
        measureIndexOffset: Int,
        location: String,
        options: PDFImportOptions,
        geometry: PDFGeometryCollector?,
    ) -> [Measure] {
        var events = scoreStateEvents(
            staff: importStaff, texts: [],
            diagnostics: options.diagnostics, location: location,
        )
        // Apply the whole-part E065 (F8va) clef resolution decided up front by
        // `resolveF8vaSlots`. Confined to the F8va case. See `remapF8vaClef`.
        events = remapF8vaClef(events, to: clefOverride)
        let priorClef = state.clef[slot]
        let priorKey = state.key[slot]
        let priorTime = state.time[slot]
        var clef = priorClef ?? Clef(concertClefType: "G")
        var key = priorKey ?? KeySignature(concertKey: 0)
        var ts = priorTime ?? TimeSignature(numerator: 4, denominator: 4)

        var out: [Measure] = []
        for (mi, importMeasure) in importStaff.measures.enumerated() {
            let beforeClef = clef
            let beforeKey = key
            let beforeTime = ts
            (clef, key, ts) = applyEvents(events, atMeasure: mi, clef: clef, key: key, ts: ts)
            // Emit clef / key / time as leading VoiceElements when this
            // measure introduces or CHANGES one relative to the running
            // state. The very first measure of a part (no prior state)
            // always emits its initial clef/key/time so consumers reading
            // B get the opening signatures — matching how A (mscz) carries
            // them on measure 0.
            let isFirstMeasureOfPart = priorClef == nil && mi == 0
            let emitClef = clef.concertClefType != beforeClef.concertClefType
                || (isFirstMeasureOfPart && clef.concertClefType != "G")
            let emitKey = key.concertKey != beforeKey.concertKey
                || (isFirstMeasureOfPart && key.concertKey != 0)
            let emitTime = (ts.numerator, ts.denominator)
                != (beforeTime.numerator, beforeTime.denominator)
                || (
                    isFirstMeasureOfPart
                        && (ts.numerator, ts.denominator) != (4, 4)
                )
            out.append(buildOneMeasure(
                importMeasure: importMeasure,
                texts: texts,
                paths: paths,
                tieMarks: tieMarks,
                graceSizeThreshold: graceSizeThreshold,
                clef: clef,
                key: key,
                ts: ts,
                emitClef: emitClef ? clef : nil,
                emitKey: emitKey ? key : nil,
                emitTime: emitTime ? ts : nil,
                pageIndex: importStaff.staff.pageIndex,
                measureIndex: mi,
                nextStaffTopY: nextStaffTopY,
                location: location,
                options: options,
                slot: slot,
                measureIndexOffset: measureIndexOffset,
                geometry: geometry,
            ))
        }
        // Fold a boundary event pointing PAST this system's last measure
        // (index == measure count) into the carried state — a to-C key
        // cancellation drawn as a trailing courtesy at the end of the
        // outgoing system, whose change takes effect at the next system's
        // first measure (which shows nothing for C major). Clefs/keys/times
        // that ARE re-shown next system just re-sync there; this only
        // matters for the silent to-C case.
        (clef, key, ts) = applyEvents(
            events, atMeasure: importStaff.measures.count,
            clef: clef, key: key, ts: ts,
        )
        state.clef[slot] = clef
        state.key[slot] = key
        state.time[slot] = ts
        return out
    }

    private static func applyEvents(
        _ events: [ScoreStateEvent],
        atMeasure mi: Int,
        clef: Clef,
        key: KeySignature,
        ts: TimeSignature,
    ) -> (Clef, KeySignature, TimeSignature) {
        var c = clef
        var k = key
        var t = ts
        for ev in events where eventMeasureIndex(ev) == mi {
            switch ev {
            case let .clefChange(newClef, _): c = newClef
            case let .keySignature(newKey, _): k = newKey
            case let .timeSignature(newTs, _): t = newTs
            case .tempo: break // MVP: deferred
            }
        }
        return (c, k, t)
    }

    private static func eventMeasureIndex(_ ev: ScoreStateEvent) -> Int {
        switch ev {
        case let .clefChange(_, i),
             let .keySignature(_, i),
             let .timeSignature(_, i),
             let .tempo(_, i):
            return i
        }
    }

    /// Build a single Measure from one ImportMeasure cell, given the
    /// running clef/key/time signature. Pure helper — `state` is updated
    /// by the caller before/after.
    private static func buildOneMeasure(
        importMeasure: ImportMeasure,
        texts: [TextGlyph],
        paths: [PathSegment],
        tieMarks: TieMarks,
        graceSizeThreshold: CGFloat,
        clef: Clef,
        key: KeySignature,
        ts: TimeSignature,
        emitClef: Clef?,
        emitKey: KeySignature?,
        emitTime: TimeSignature?,
        pageIndex: Int,
        measureIndex: Int,
        nextStaffTopY: CGFloat?,
        location: String,
        options: PDFImportOptions,
        slot: Int,
        measureIndexOffset: Int,
        geometry: PDFGeometryCollector?,
    ) -> Measure {
        let decoded = decodePitches(measure: importMeasure, activeClef: clef, activeKey: key)
        let rhythm = decodeRhythm(
            measure: importMeasure, decoded: decoded, paths: paths, tieMarks: tieMarks,
            graceSizeThreshold: graceSizeThreshold,
        )
        // Tuplet marks (the engraved number, plus its bracket when one is
        // drawn) are read BEFORE lyrics so a claimed digit cannot also
        // become a syllable, and before reconciliation so the metric repair
        // sees the true tuplet values and spends its one change on the
        // neighbouring note instead. See PDFImporter+TupletMark.
        let tupletMarks = detectTupletMarks(
            texts: texts,
            paths: paths,
            staffYLines: importMeasure.staffYLines,
            xRange: importMeasure.xRange,
            pageIndex: pageIndex,
        )
        let withLyrics = attachLyrics(
            elements: rhythm,
            texts: texts,
            staffYLines: importMeasure.staffYLines,
            pageIndex: pageIndex,
            xRange: importMeasure.xRange,
            nextStaffTopY: nextStaffTopY,
            excludingOrigins: tupletMarks.map(\.digitOrigin),
        )
        let withTuplets = applyTupletMarks(
            elements: withLyrics,
            marks: tupletMarks,
            spatium: staffSpatium(importMeasure.staffYLines),
        )
        // Metric-sum reconciliation (③): repair a voice whose note + rest
        // durations don't total the bar length by re-valuing exactly one
        // low-confidence note. Conservative + monotonic — a voice already at
        // the bar length is untouched. See PDFImporter+RhythmReconcile.
        let reconciled = reconcileMeasureDurations(
            elements: withTuplets,
            timeSignature: ts,
            spatium: staffSpatium(importMeasure.staffYLines),
            diagnostics: options.diagnostics,
            location: "\(location), measure \(measureIndex)",
        )
        let staffMidY = staffMidline(importMeasure.staffYLines)
        let voices = assignVoices(
            elements: reconciled,
            measureXRange: importMeasure.xRange,
            timeSignature: ts,
            staffMidY: staffMidY,
            diagnostics: options.diagnostics,
            location: "\(location), measure \(measureIndex)",
        )
        let (finalVoices, leadingCount) = prependingScoreState(
            voices, clef: emitClef, key: emitKey, time: emitTime,
        )
        recordGeometry(
            geometry,
            reconciled: reconciled,
            staffMidY: staffMidY,
            leadingCount: leadingCount,
            importMeasure: importMeasure,
            slot: slot,
            measureIndex: measureIndexOffset + measureIndex,
            pageIndex: pageIndex,
        )
        return Measure(voices: finalVoices)
    }

    /// Prepend the score-state elements (clef → key → time order) into the
    /// first voice so consumers and the per-measure state comparison see
    /// them, mirroring how A (mscz) carries them on the measure. Also
    /// reports how many were prepended, which the geometry side-car needs
    /// to keep its element indices aligned with the returned voices.
    private static func prependingScoreState(
        _ voices: [Voice],
        clef: Clef?,
        key: KeySignature?,
        time: TimeSignature?,
    ) -> (voices: [Voice], leadingCount: Int) {
        var leading: [VoiceElement] = []
        if let clef { leading.append(.clef(clef)) }
        if let key { leading.append(.keySignature(key)) }
        if let time { leading.append(.timeSignature(time)) }
        var out = voices.isEmpty ? [Voice(elements: [])] : voices
        if !leading.isEmpty {
            out[0] = Voice(elements: leading + out[0].elements)
        }
        return (out, leading.count)
    }

    /// Record per-element + measure-cell geometry for the side-car, using
    /// the SAME `voiceAssignment` permutation `assignVoices` built so each
    /// element's (voiceIndex, elementIndex) matches `finalVoices`. No-op
    /// when `geometry` is `nil` (the plain `parse` path).
    private static func recordGeometry(
        _ geometry: PDFGeometryCollector?,
        reconciled: [RhythmElement],
        staffMidY: CGFloat,
        leadingCount: Int,
        importMeasure: ImportMeasure,
        slot: Int,
        measureIndex: Int,
        pageIndex: Int,
    ) {
        guard let geometry else { return }
        geometry.recordMeasureCell(
            slot: slot, measureIndex: measureIndex,
            xRange: importMeasure.xRange,
            yLines: importMeasure.staffYLines,
            pageIndex: pageIndex,
        )
        let placements = voiceAssignment(elements: reconciled, staffMidY: staffMidY)
        for (i, element) in reconciled.enumerated() {
            guard let onsetRect = element.onsetRect else { continue }
            let p = placements[i]
            // Voice 0's chord/rest indices are shifted right by the leading
            // clef/key/time elements prepended into finalVoices[0].
            let elementIndex = p.position + (p.voice == 0 ? leadingCount : 0)
            assert(
                element.isRest || element.noteRects.count == element.chord.notes.count,
                "PDF geometry: noteRects/notes misaligned",
            )
            geometry.recordItem(
                slot: slot, measureIndex: measureIndex,
                voiceIndex: p.voice, elementIndex: elementIndex,
                isRest: element.isRest, onsetRect: onsetRect,
                noteRects: element.noteRects,
            )
        }
    }

    private static func staffMidline(_ ys: [CGFloat]) -> CGFloat {
        guard let lo = ys.first, let hi = ys.last else { return 0 }
        return (lo + hi) / 2
    }
}
