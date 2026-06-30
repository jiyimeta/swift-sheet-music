import CoreGraphics
import Foundation
import SheetMusicCore

// Recover tempo markings ("♩ = NN") from the PDF's page text into
// `Score.systemMeasures`, so `PlaybackTimeline` plays at the engraved BPM
// instead of the 120 default. MuseScore emits one TextGlyph per character,
// so the digits arrive split and are merged (`mergeTextRuns`) before parsing.

extension PDFImporter {
    /// One top-staff measure cell, used to map a tempo text to its measure.
    private struct TempoCell {
        let measureIndex: Int
        let pageIndex: Int
        let xRange: ClosedRange<CGFloat>
        let topY: CGFloat // top staff line (PDF y-up: larger = higher)
        let spatium: CGFloat
    }

    /// Build `Score.systemMeasures` carrying the tempo markings recovered
    /// from the page text. Each `= NN` marking is mapped to the measure it
    /// sits above (same page, x over the measure, staff just below the text)
    /// and emitted as a `.tempo` at that measure's downbeat. Returns `[]`
    /// when no tempo marking is found.
    static func tempoSystemMeasures(
        systems: [ImportSystem], texts: [TextGlyph], measureCount: Int,
    ) -> [SystemMeasure] {
        let cells = tempoCells(systems: systems)
        guard !cells.isEmpty else { return [] }
        var byMeasure: [Int: Tempo] = [:]
        // MuseScore emits one TextGlyph per character, so "= 80" arrives as
        // separate "=", "8", "0" glyphs — merge them into runs (per page)
        // before reading the BPM. Mirrors the title extractor.
        let pages = Set(texts.map(\.pageIndex)).sorted()
        for page in pages {
            let runs = mergeTextRuns(texts.filter { $0.pageIndex == page })
            for run in runs {
                guard let bpm = parseBpm(from: run.text),
                      let mi = nearestTempoMeasure(
                          x: run.x, y: run.y, page: page, cells: cells,
                      )
                else { continue }
                // First marking wins per measure (avoids a stray duplicate
                // run overwriting the real one).
                if byMeasure[mi] == nil {
                    byMeasure[mi] = Tempo(beatsPerSecond: Double(bpm) / 60.0)
                }
            }
        }
        guard !byMeasure.isEmpty else { return [] }
        let count = max(measureCount, (byMeasure.keys.max() ?? 0) + 1)
        var result = Array(repeating: SystemMeasure(), count: count)
        for (mi, tempo) in byMeasure where mi < count {
            result[mi] = SystemMeasure(elements: [
                PositionedSystemElement(position: .start, element: .tempo(tempo)),
            ])
        }
        return result
    }

    /// Top-staff measure cells in global measure order (their index matches
    /// `Score.parts[0].staves[0].measures` for a full ensemble).
    private static func tempoCells(systems: [ImportSystem]) -> [TempoCell] {
        var cells: [TempoCell] = []
        var globalIndex = 0
        for system in systems {
            guard let topStaff = system.parts.first?.staves.first else { continue }
            let yLines = topStaff.staff.yLines
            let topY = yLines.max() ?? system.yRange.upperBound
            let spatium = staffSpatium(yLines)
            for measure in topStaff.measures {
                cells.append(TempoCell(
                    measureIndex: globalIndex, pageIndex: system.pageIndex,
                    xRange: measure.xRange, topY: topY, spatium: spatium,
                ))
                globalIndex += 1
            }
        }
        return cells
    }

    /// Measure index of the cell a tempo text sits above: same page, x over
    /// the measure (with a left slop for the marking hanging left of the
    /// barline), and the staff top just below the text. Picks the closest
    /// staff below when several overlap.
    private static func nearestTempoMeasure(
        x tx: CGFloat, y ty: CGFloat, page: Int, cells: [TempoCell],
    ) -> Int? {
        var best: TempoCell?
        for c in cells where c.pageIndex == page {
            guard tx >= c.xRange.lowerBound - c.spatium * 2,
                  tx <= c.xRange.upperBound else { continue }
            let dy = ty - c.topY // > 0 ⇒ text above the staff top
            guard dy >= -c.spatium, dy <= c.spatium * 12 else { continue }
            if let b = best {
                if c.topY > b.topY
                    || (c.topY == b.topY
                        && abs(tx - c.xRange.lowerBound) < abs(tx - b.xRange.lowerBound))
                {
                    best = c
                }
            } else {
                best = c
            }
        }
        return best?.measureIndex
    }

    /// Parse the BPM from a merged run like "=80" / "♩ = 132" — the integer
    /// following the last `=`. Returns `nil` when there's no numeric
    /// equation.
    private static func parseBpm(from text: String) -> Int? {
        guard let equalsIdx = text.lastIndex(of: "=") else { return nil }
        let after = text[text.index(after: equalsIdx)...]
            .trimmingCharacters(in: .whitespaces)
        let numericPrefix = after.prefix { $0.isNumber }
        guard !numericPrefix.isEmpty,
              let bpm = Int(numericPrefix), bpm > 0 else { return nil }
        return bpm
    }
}
