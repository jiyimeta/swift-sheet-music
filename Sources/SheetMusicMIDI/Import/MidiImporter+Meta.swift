import Foundation
import SheetMusicCore

extension MidiImporter {
    /// Build a tick→measureIndex map and per-track per-measure
    /// `ImportMeasure` slices. Time-signature meta events from any
    /// ImportTrack contribute to the global map.
    static func segmentBars(
        imports: [ImportTrack],
        division: Int
    ) -> [[ImportMeasure]] {
        let timeline = buildBarTimeline(imports: imports, division: division)
        return imports.map { segment(track: $0, timeline: timeline) }
    }

    /// Public for testing.
    static func buildBarTimeline(imports: [ImportTrack], division: Int) -> BarTimeline {
        struct Change { var tick: Int; var sig: TimeSignature }
        var changes: [Change] = []
        for track in imports {
            for ev in track.events {
                if case let .meta(.timeSignature(n, d, _, _)) = ev.event {
                    changes.append(Change(
                        tick: ev.tick,
                        sig: TimeSignature(numerator: n, denominator: d)
                    ))
                }
            }
        }
        changes.sort { $0.tick < $1.tick }
        if changes.first?.tick != 0 {
            changes.insert(
                Change(tick: 0, sig: TimeSignature(numerator: 4, denominator: 4)),
                at: 0
            )
        }

        let lastTick = imports.flatMap(\.events).map(\.tick).max() ?? 0

        var bars: [BarTimeline.Bar] = []
        var measureIndex = 0
        for (i, change) in changes.enumerated() {
            let segmentEnd = i + 1 < changes.count ? changes[i + 1].tick : lastTick
            let barLen = barTicks(sig: change.sig, division: division)
            var t = change.tick
            while t < segmentEnd {
                bars.append(BarTimeline.Bar(
                    index: measureIndex,
                    startTick: t,
                    endTick: min(t + barLen, segmentEnd),
                    timeSignature: change.sig
                ))
                measureIndex += 1
                t += barLen
            }
        }

        return BarTimeline(bars: bars)
    }

    static func barTicks(sig: TimeSignature, division: Int) -> Int {
        // beats per bar × ticks per beat
        // ticks per beat = division × 4 / denominator
        (division * 4 * sig.numerator) / sig.denominator
    }

    static func segment(
        track: ImportTrack, timeline: BarTimeline
    ) -> [ImportMeasure] {
        // Pair noteOn with noteOff (per channel/pitch) so we can
        // detect bar-crossing notes.
        struct OpenNote { var pitch: Int; var channel: Int; var onTick: Int }
        var open: [OpenNote] = []
        var pairs: [(on: Int, off: Int, pitch: Int, channel: Int)] = []
        for ev in track.events {
            switch ev.event {
            case let .noteOn(c, p, v) where v > 0:
                open.append(OpenNote(pitch: p, channel: c, onTick: ev.tick))
            case let .noteOn(c, p, _),
                 let .noteOff(c, p, _):
                if let idx = open.firstIndex(where: { $0.pitch == p && $0.channel == c }) {
                    let n = open.remove(at: idx)
                    pairs.append((on: n.onTick, off: ev.tick, pitch: p, channel: c))
                }
            default:
                break
            }
        }
        // Force-close anything still open at the last event tick.
        let lastTick = track.events.map(\.tick).max() ?? 0
        for n in open {
            pairs.append((on: n.onTick, off: lastTick, pitch: n.pitch, channel: n.channel))
        }

        var measures: [ImportMeasure] = []
        for bar in timeline.bars {
            var slice = ImportMeasure(
                startTick: bar.startTick,
                endTick: bar.endTick,
                measureIndex: bar.index,
                timeSignature: bar.timeSignature,
                events: track.events.filter { bar.startTick <= $0.tick && $0.tick < bar.endTick },
                carryIns: [],
                carryOuts: []
            )
            for p in pairs {
                let onBar = timeline.measureIndex(of: p.on)
                let offBar = timeline.measureIndex(of: max(p.off - 1, p.on))
                if onBar != offBar {
                    if onBar == bar.index {
                        slice.carryOuts.append(CarriedNote(
                            pitch: p.pitch, channel: p.channel,
                            sourceMeasureIndex: onBar,
                            noteOnTick: p.on, noteOffTick: p.off
                        ))
                    }
                    if onBar < bar.index && bar.index <= offBar {
                        slice.carryIns.append(CarriedNote(
                            pitch: p.pitch, channel: p.channel,
                            sourceMeasureIndex: onBar,
                            noteOnTick: p.on, noteOffTick: p.off
                        ))
                    }
                }
            }
            measures.append(slice)
        }
        return measures
    }
}

struct BarTimeline {
    struct Bar {
        var index: Int
        var startTick: Int
        var endTick: Int
        var timeSignature: TimeSignature
    }

    var bars: [Bar]

    func measureIndex(of tick: Int) -> Int {
        for bar in bars where bar.startTick <= tick && tick < bar.endTick {
            return bar.index
        }
        return bars.last?.index ?? 0
    }
}
