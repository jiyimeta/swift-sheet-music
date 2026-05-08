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
        options: PDFImportOptions
    ) -> Score {
        guard let firstSystem = systems.first else {
            return Score(division: 480, source: .pdf)
        }
        let shape = partShape(from: firstSystem)
        var stavesContent: [[Measure]] = Array(
            repeating: [], count: shape.totalStaffSlots
        )
        var state = StaffStateMap()
        let pageBoundaries = systemPageBoundaries(systems)

        for (sysIndex, system) in systems.enumerated() {
            appendSystem(
                system: system,
                sysIndex: sysIndex,
                isLastInPage: pageBoundaries.contains(sysIndex),
                isLastSystem: sysIndex == systems.count - 1,
                shape: shape,
                texts: texts,
                stavesContent: &stavesContent,
                state: &state,
                options: options
            )
        }

        // Distribute measure arrays back into each Part's staves.
        var assembledParts = shape.parts
        for (partIdx, slots) in shape.slotsByPartIndex {
            for (staffIdx, slot) in slots.enumerated() {
                assembledParts[partIdx].staves[staffIdx].measures = stavesContent[slot]
            }
        }
        let titleFrame = makeTitleFrame(
            document: document, texts: texts, options: options
        )
        return Score(
            division: 480,
            parts: assembledParts,
            titleFrame: titleFrame,
            source: .pdf
        )
    }

    // MARK: - Part shape

    /// Map of `firstSystem.parts[i]` → flat staff-slot indices, plus
    /// the assembled `Part` list with placeholder instruments.
    fileprivate struct PartShape {
        var parts: [Part]
        var slotsByPartIndex: [Int: [Int]]
        var totalStaffSlots: Int
    }

    private static func partShape(from firstSystem: ImportSystem) -> PartShape {
        var parts: [Part] = []
        var slotsByPartIndex: [Int: [Int]] = [:]
        var nextSlot = 0
        for (partIdx, partProto) in firstSystem.parts.enumerated() {
            let staffCount = partProto.staves.count
            let part = Part(
                id: "P\(partIdx + 1)",
                trackName: nil,
                instrument: Instrument(id: "voice"),
                staves: Array(
                    repeating: SheetMusicCore.Staff(staffType: "stdNormal", group: "pitched"),
                    count: staffCount
                )
            )
            parts.append(part)
            var slots: [Int] = []
            for _ in 0 ..< staffCount {
                slots.append(nextSlot)
                nextSlot += 1
            }
            slotsByPartIndex[partIdx] = slots
        }
        return PartShape(
            parts: parts,
            slotsByPartIndex: slotsByPartIndex,
            totalStaffSlots: nextSlot
        )
    }

    // MARK: - System append

    // Append every staff's measures from one system into the running
    // `stavesContent`. Updates `state` (per-slot clef/key/time) and
    // applies break flags when `options.preserveBreaks` is on.
    // swiftlint:disable:next function_parameter_count
    private static func appendSystem(
        system: ImportSystem,
        sysIndex: Int,
        isLastInPage: Bool,
        isLastSystem: Bool,
        shape: PartShape,
        texts: [TextGlyph],
        stavesContent: inout [[Measure]],
        state: inout StaffStateMap,
        options: PDFImportOptions
    ) {
        for (partIdx, importPart) in system.parts.enumerated() {
            guard let slots = shape.slotsByPartIndex[partIdx] else { continue }
            // Defensive: a later system might have extra staves not
            // present in the first system. Ignore the surplus rather
            // than crash.
            let pairs = zip(slots, importPart.staves)
            for (slot, importStaff) in pairs {
                let location = "page \(system.pageIndex), system \(sysIndex)"
                let measures = buildMeasures(
                    importStaff: importStaff,
                    texts: texts,
                    state: &state,
                    slot: slot,
                    location: location,
                    options: options
                )
                stavesContent[slot].append(contentsOf: measures)
                applyBreaks(
                    to: &stavesContent[slot],
                    appended: measures.count,
                    isLastInPage: isLastInPage,
                    isLastSystem: isLastSystem,
                    options: options
                )
            }
        }
    }

    private static func applyBreaks(
        to measures: inout [Measure],
        appended: Int,
        isLastInPage: Bool,
        isLastSystem: Bool,
        options: PDFImportOptions
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

    // MARK: - Title frame

    private static func makeTitleFrame(
        document: PDFDocument,
        texts: [TextGlyph],
        options: PDFImportOptions
    ) -> ScoreFrame? {
        let firstPage = document.page(at: 0)
        let pageSize = firstPage?.bounds(for: .mediaBox).size
            ?? CGSize(width: 595, height: 842)
        return extractTitleFrame(
            texts: texts,
            pageSize: pageSize,
            documentAttributes: document.documentAttributes as? [String: Any],
            options: options
        )
    }

    /// Sort + scan to identify systems whose successor is on a different
    /// page (or the last system overall). The LAST system is also a page
    /// boundary because there's no "next page" to migrate to.
    private static func systemPageBoundaries(_ systems: [ImportSystem]) -> Set<Int> {
        var boundaries = Set<Int>()
        for i in 0 ..< systems.count {
            let isLast = i == systems.count - 1
            if isLast || systems[i].pageIndex != systems[i + 1].pageIndex {
                boundaries.insert(i)
            }
        }
        return boundaries
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
        state: inout StaffStateMap,
        slot: Int,
        location: String,
        options: PDFImportOptions
    ) -> [Measure] {
        let events = scoreStateEvents(staff: importStaff, texts: [])
        var clef = state.clef[slot] ?? Clef(concertClefType: "G")
        var key = state.key[slot] ?? KeySignature(concertKey: 0)
        var ts = state.time[slot] ?? TimeSignature(numerator: 4, denominator: 4)

        var out: [Measure] = []
        for (mi, importMeasure) in importStaff.measures.enumerated() {
            (clef, key, ts) = applyEvents(events, atMeasure: mi, clef: clef, key: key, ts: ts)
            out.append(buildOneMeasure(
                importMeasure: importMeasure,
                texts: texts,
                clef: clef,
                key: key,
                ts: ts,
                pageIndex: importStaff.staff.pageIndex,
                measureIndex: mi,
                location: location,
                options: options
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
        ts: TimeSignature
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

    // Build a single Measure from one ImportMeasure cell, given the
    // running clef/key/time signature. Pure helper — `state` is updated
    // by the caller before/after.
    // swiftlint:disable:next function_parameter_count
    private static func buildOneMeasure(
        importMeasure: ImportMeasure,
        texts: [TextGlyph],
        clef: Clef,
        key: KeySignature,
        ts: TimeSignature,
        pageIndex: Int,
        measureIndex: Int,
        location: String,
        options: PDFImportOptions
    ) -> Measure {
        let decoded = decodePitches(measure: importMeasure, activeClef: clef, activeKey: key)
        let rhythm = decodeRhythm(measure: importMeasure, decoded: decoded, paths: [])
        let withLyrics = attachLyrics(
            elements: rhythm,
            texts: texts,
            staffYLines: importMeasure.staffYLines,
            pageIndex: pageIndex
        )
        let staffMidY = staffMidline(importMeasure.staffYLines)
        let voices = assignVoices(
            elements: withLyrics,
            measureXRange: importMeasure.xRange,
            timeSignature: ts,
            staffMidY: staffMidY,
            diagnostics: options.diagnostics,
            location: "\(location), measure \(measureIndex)"
        )
        return Measure(voices: voices.isEmpty ? [Voice(elements: [])] : voices)
    }

    private static func staffMidline(_ ys: [CGFloat]) -> CGFloat {
        guard let lo = ys.first, let hi = ys.last else { return 0 }
        return (lo + hi) / 2
    }
}
