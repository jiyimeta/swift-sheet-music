import CoreGraphics
import Foundation
import PDFKit
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
        document: PDFDocument,
        systems: [ImportSystem],
        texts: [TextGlyph],
        classified: [ClassifiedGlyph],
        paths: [PathSegment],
        tieMarks: TieMarks = TieMarks(),
        graceSizeThreshold: CGFloat = 0,
        options: PDFImportOptions,
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
            )
        }

        // Distribute measure arrays back into each Part's staves.
        var assembledParts = shape.parts
        for (partIdx, slots) in shape.slotsByPartIndex {
            for (staffIdx, slot) in slots.enumerated() {
                assembledParts[partIdx].staves[staffIdx].measures = stavesContent[slot]
            }
        }
        // Propagate pitch along tie chains: a tied-back note inherits its
        // source note's pitch (incl. any accidental MuseScore did not redraw
        // on the continuation). Conservative + monotonic — only a genuine
        // mismatch is repaired. See PDFImporter+TiePitch.
        propagateTiePitches(parts: &assembledParts)
        let titleFrame = makeTitleFrame(
            document: document, texts: texts, options: options,
        )
        return Score(
            division: 480,
            parts: assembledParts,
            titleFrame: titleFrame,
            source: .pdf,
        )
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
    ) {
        // Stems / barlines etc. are page-local; pre-filter to this
        // system's page so a vertical at the same x on another page can't
        // be mistaken for a stem in `decodeRhythm`'s xRange test.
        let pagePaths = paths.filter { $0.pageIndex == system.pageIndex }
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
                let measures = buildMeasures(
                    importStaff: importStaff,
                    texts: texts,
                    paths: pagePaths,
                    tieMarks: tieMarks,
                    graceSizeThreshold: graceSizeThreshold,
                    clefOverride: clefOverrides[slot],
                    state: &state,
                    slot: slot,
                    location: location,
                    options: options,
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

    /// Walk `importStaff.measures` left-to-right, applying score-state
    /// events from this staff and producing a `Measure` per cell.
    fileprivate static func buildMeasures(
        importStaff: ImportStaff,
        texts: [TextGlyph],
        paths: [PathSegment],
        tieMarks: TieMarks,
        graceSizeThreshold: CGFloat,
        clefOverride: Clef?,
        state: inout StaffStateMap,
        slot: Int,
        location: String,
        options: PDFImportOptions,
    ) -> [Measure] {
        var events = scoreStateEvents(staff: importStaff, texts: [])
        // Apply the whole-part E065 (F8va) clef resolution decided up front by
        // `resolveF8vaSlots`: rewrite every F8va clef event on this slot to the
        // resolved clef (plain F). Confined to the F8va case — other clefs are
        // untouched. See `disambiguateF8vaClef`.
        if let clefOverride {
            events = events.map { ev in
                if case let .clefChange(c, mi) = ev, c.concertClefType == "F8va" {
                    return .clefChange(clefOverride, atMeasureIndex: mi)
                }
                return ev
            }
        }
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
                location: location,
                options: options,
            ))
        }
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
        location: String,
        options: PDFImportOptions,
    ) -> Measure {
        let decoded = decodePitches(measure: importMeasure, activeClef: clef, activeKey: key)
        let rhythm = decodeRhythm(
            measure: importMeasure, decoded: decoded, paths: paths, tieMarks: tieMarks,
            graceSizeThreshold: graceSizeThreshold,
        )
        let withLyrics = attachLyrics(
            elements: rhythm,
            texts: texts,
            staffYLines: importMeasure.staffYLines,
            pageIndex: pageIndex,
            xRange: importMeasure.xRange,
        )
        // Metric-sum reconciliation (③): repair a voice whose note + rest
        // durations don't total the bar length by re-valuing exactly one
        // low-confidence note. Conservative + monotonic — a voice already at
        // the bar length is untouched. See PDFImporter+RhythmReconcile.
        let reconciled = reconcileMeasureDurations(
            elements: withLyrics,
            timeSignature: ts,
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
        // Prepend score-state elements (clef → key → time order) into the
        // first voice so consumers and the per-measure state comparison see
        // them, mirroring how A (mscz) carries them on the measure.
        var leading: [VoiceElement] = []
        if let emitClef { leading.append(.clef(emitClef)) }
        if let emitKey { leading.append(.keySignature(emitKey)) }
        if let emitTime { leading.append(.timeSignature(emitTime)) }
        var finalVoices = voices.isEmpty ? [Voice(elements: [])] : voices
        if !leading.isEmpty {
            finalVoices[0] = Voice(elements: leading + finalVoices[0].elements)
        }
        return Measure(voices: finalVoices)
    }

    private static func staffMidline(_ ys: [CGFloat]) -> CGFloat {
        guard let lo = ys.first, let hi = ys.last else { return 0 }
        return (lo + hi) / 2
    }
}
