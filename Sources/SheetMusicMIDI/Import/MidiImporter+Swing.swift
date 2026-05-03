import Foundation
import SheetMusicCore

extension MidiImporter {
    /// Detect swing in an ImportTrack and, if confidence is high
    /// enough, ask the resolver whether to straighten timing. Returns
    /// the (possibly-rewritten) track. If the resolver answers
    /// `.treatAsWritten`, or detection fails, the track is returned
    /// unchanged.
    static func analyzeSwing(
        track: ImportTrack,
        timeline: BarTimeline,
        division: Int,
        resolve: (SwingDetection) -> SwingResolution
    ) -> ImportTrack {
        guard let detection = detectSwing(
            track: track, timeline: timeline, division: division
        ) else { return track }
        switch resolve(detection) {
        case .treatAsWritten: return track
        case .treatAsSwing:
            let beat = (division * 4) / 4
            return straighten(track: track, beat: beat)
        }
    }

    /// Pure detection — returns nil if no swing pattern was found.
    /// Extracted so the async parse path can share it.
    static func detectSwing(
        track: ImportTrack,
        timeline: BarTimeline,
        division: Int
    ) -> SwingDetection? {
        let onsets = track.events.compactMap { ev -> Int? in
            if case let .noteOn(_, _, v) = ev.event, v > 0 { return ev.tick }
            return nil
        }.sorted()
        guard onsets.count >= 16 else { return nil }

        let beat = (division * 4) / 4
        var ratios: [Double] = []
        var beatStart = 0
        let lastTick = onsets.last ?? 0
        while beatStart < lastTick {
            let beatEnd = beatStart + beat
            let inBeat = onsets.filter { $0 >= beatStart && $0 < beatEnd }
            if inBeat.count == 2 {
                let frontLen = Double(inBeat[1] - inBeat[0])
                let backLen = Double(beatEnd - inBeat[1])
                if frontLen > 0 {
                    ratios.append(backLen / frontLen)
                }
            }
            beatStart = beatEnd
        }
        guard ratios.count >= 8 else { return nil }
        let mean = ratios.reduce(0, +) / Double(ratios.count)
        let variance = ratios.map { ($0 - mean) * ($0 - mean) }
            .reduce(0, +) / Double(ratios.count)
        let stddev = variance.squareRoot()
        guard mean >= 1.4, mean <= 2.5, stddev < 0.15 else { return nil }

        return SwingDetection(
            trackIndex: track.trackIndex,
            measureRange: 0 ..< (timeline.bars.last?.index ?? 0) + 1,
            estimatedRatio: mean,
            confidence: max(0, min(1, 1 - stddev / 0.2)),
            sampleSize: ratios.count
        )
    }

    /// Snap each tick within a beat to one of {0, beat/2, beat}.
    /// This collapses 2:1 / 1.5:1 swing to straight 8ths.
    static func straighten(track: ImportTrack, beat: Int) -> ImportTrack {
        var copy = track
        for i in copy.events.indices {
            let tick = copy.events[i].tick
            let beatStart = (tick / beat) * beat
            let inBeatOffset = tick - beatStart
            let snapped: Int
            if inBeatOffset < beat / 4 {
                snapped = 0
            } else if inBeatOffset < (3 * beat) / 4 {
                snapped = beat / 2
            } else {
                snapped = beat
            }
            copy.events[i] = TimedMidiEvent(
                tick: beatStart + snapped, event: copy.events[i].event
            )
        }
        copy.events.sort { $0.tick < $1.tick }
        return copy
    }
}
