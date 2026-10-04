import SheetMusicCore
import SheetMusicFoundation

extension MidiImporter {
    /// Build a tick→measureIndex map and per-track per-measure
    /// `ImportMeasure` slices. Time-signature meta events from any
    /// ImportTrack contribute to the global map.
    static func segmentBars(
        imports: [ImportTrack],
        division: Int,
    ) -> [[ImportMeasure]] {
        let timeline = buildBarTimeline(imports: imports, division: division)
        return imports.map { segment(track: $0, timeline: timeline) }
    }

    /// Public for testing.
    ///
    /// The meter comes from `imports` AND `fileEvents` — every track of the file, the conductor included. A
    /// Format 1 file keeps its time signatures on track 0, which carries no notes and so yields no `ImportTrack`;
    /// reading the slices alone cut a 3/4 piece into 4/4 bars. MuseScore builds its map from every track's meta
    /// events the same way (`createMTrackList`), a later track's signature replacing an earlier one at the same
    /// tick. The timeline's extent still comes from `imports` alone.
    ///
    /// The last bar is always a whole bar, the music's end rounded up to the barline (MuseScore's
    /// `createMeasures`). A drum slice carries no `endOfTrack`, so a file whose only notes are drum hits used to end
    /// its last bar at the final hit's release. Only the final segment rounds: a bar cut by a later time-signature
    /// change keeps the cut.
    static func buildBarTimeline(
        imports: [ImportTrack], division: Int, fileEvents: [TimedMidiEvent] = [],
    ) -> BarTimeline {
        struct Change { var tick: Int; var sig: TimeSignature }
        var signatureAt: [Int: TimeSignature] = [:]
        for ev in imports.flatMap(\.events) + fileEvents {
            if case let .meta(.timeSignature(n, d, _, _)) = ev.event {
                signatureAt[ev.tick] = TimeSignature(numerator: n, denominator: d)
            }
        }
        var changes = signatureAt.map { Change(tick: $0.key, sig: $0.value) }
        changes.sort { $0.tick < $1.tick }
        if changes.first?.tick != 0 {
            changes.insert(
                Change(tick: 0, sig: TimeSignature(numerator: 4, denominator: 4)),
                at: 0,
            )
        }

        let lastTick = imports.flatMap(\.events).map(\.tick).max() ?? 0

        var bars: [BarTimeline.Bar] = []
        var measureIndex = 0
        for (i, change) in changes.enumerated() {
            let isFinalSegment = i + 1 == changes.count
            let segmentEnd = isFinalSegment ? lastTick : changes[i + 1].tick
            let barLen = barTicks(sig: change.sig, division: division)
            var t = change.tick
            while t < segmentEnd {
                let wholeBarEnd = t + barLen
                let endTick = isFinalSegment ? wholeBarEnd : min(wholeBarEnd, segmentEnd)
                bars.append(BarTimeline.Bar(
                    index: measureIndex,
                    startTick: t,
                    endTick: endTick,
                    timeSignature: change.sig,
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

    /// One sounding note recovered from a track's event stream.
    struct NoteSpan {
        var on: Int
        var off: Int
        var pitch: Int
        var channel: Int
        /// Velocity of the noteOn, carried so bar-crossing notes can
        /// stamp it on every measure they reach.
        var velocity: Int
    }

    /// Pair each noteOn with its noteOff (per channel / pitch) so
    /// `segment` can detect bar-crossing notes. Anything still open at
    /// the end is force-closed at the track's last event tick.
    static func noteSpans(in track: ImportTrack) -> [NoteSpan] {
        struct OpenNote { var pitch: Int; var channel: Int; var onTick: Int; var velocity: Int }
        var open: [OpenNote] = []
        var spans: [NoteSpan] = []
        for ev in track.events {
            switch ev.event {
            case let .noteOn(c, p, v) where v > 0:
                open.append(OpenNote(pitch: p, channel: c, onTick: ev.tick, velocity: v))
            case let .noteOn(c, p, _),
                 let .noteOff(c, p, _):
                if let idx = open.firstIndex(where: { $0.pitch == p && $0.channel == c }) {
                    let n = open.remove(at: idx)
                    spans.append(NoteSpan(
                        on: n.onTick, off: ev.tick, pitch: p,
                        channel: c, velocity: n.velocity,
                    ))
                }
            default:
                break
            }
        }
        let lastTick = track.events.map(\.tick).max() ?? 0
        for n in open {
            spans.append(NoteSpan(
                on: n.onTick, off: lastTick, pitch: n.pitch,
                channel: n.channel, velocity: n.velocity,
            ))
        }
        return spans
    }

    static func segment(
        track: ImportTrack, timeline: BarTimeline,
    ) -> [ImportMeasure] {
        let pairs = noteSpans(in: track)
        var measures: [ImportMeasure] = []
        for bar in timeline.bars {
            var slice = ImportMeasure(
                startTick: bar.startTick,
                endTick: bar.endTick,
                measureIndex: bar.index,
                timeSignature: bar.timeSignature,
                events: track.events.filter { bar.startTick <= $0.tick && $0.tick < bar.endTick },
                carryIns: [],
                carryOuts: [],
            )
            for p in pairs {
                let onBar = timeline.measureIndex(of: p.on)
                let offBar = timeline.measureIndex(of: max(p.off - 1, p.on))
                if onBar != offBar {
                    if onBar == bar.index {
                        slice.carryOuts.append(CarriedNote(
                            pitch: p.pitch, channel: p.channel,
                            sourceMeasureIndex: onBar,
                            noteOnTick: p.on, noteOffTick: p.off,
                            velocity: p.velocity,
                        ))
                    }
                    if onBar < bar.index && bar.index <= offBar {
                        slice.carryIns.append(CarriedNote(
                            pitch: p.pitch, channel: p.channel,
                            sourceMeasureIndex: onBar,
                            noteOnTick: p.on, noteOffTick: p.off,
                            velocity: p.velocity,
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
