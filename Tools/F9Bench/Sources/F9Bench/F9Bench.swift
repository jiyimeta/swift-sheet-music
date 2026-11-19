import Foundation
import SheetMusicCore
import SheetMusicLoader

// F9 benchmark: the per-element timing questions a selection gate asks, over every chord and rest of a score.
//
//   swift run -c release F9Bench <score.mscz|.mscx> [repeats]
//
// Prints, per question, the median over `repeats` rounds of the microseconds one call took. Uses public API only, so
// the same source builds against the base commit and the branch.

@main
enum F9Bench {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            print("usage: F9Bench <score.mscz|.mscx> [repeats]")
            exit(2)
        }
        let repeats = arguments.count >= 3 ? Int(arguments[2]) ?? 5 : 5
        var score = try ScoreLoader.loadScore(contentsOf: URL(fileURLWithPath: arguments[1]))
        let slots = chordsAndRests(of: score)
        let measureCount = score.allStaves.first?.staff.measures.count ?? 0
        print("score: \(score.allStaves.count) staves, \(measureCount) measures, \(slots.count) chords and rests")

        let frozen = score
        measure("effectiveMeasureDuration(at:)", slots: slots, repeats: repeats) { slot in
            frozen.effectiveMeasureDuration(at: slot.staff, measureIndex: slot.measureIndex).numerator
        }
        measure("resolveTickInMeasure(for:)", slots: slots, repeats: repeats) { slot in
            let rest = RestID(
                staff: slot.staff, measureIndex: slot.measureIndex, voiceIndex: slot.voiceIndex,
                elementIndex: slot.elementIndex,
            )
            return frozen.resolveTickInMeasure(for: .rest(rest)) ?? 0
        }
        measure("chronologicalBounds(of:)", slots: slots, repeats: repeats) { slot in
            frozen.chronologicalBounds(of: VoiceElementRange(start: slot, end: slot)) == nil ? 0 : 1
        }
        measure("voiceElements(in: one slot)", slots: slots, repeats: repeats) { slot in
            frozen.voiceElements(in: VoiceElementRange(start: slot, end: slot)).count
        }

        // A write, then a read: the cache is dropped every time, so this is what an edit loop pays. It must not get
        // worse.
        let writeSlots = Array(slots.prefix(500))
        var writes: [Double] = []
        for _ in 0 ..< repeats {
            let started = ContinuousClock.now
            for slot in writeSlots {
                rewrite(slot, in: &score)
                _ = score.effectiveMeasureDuration(at: slot.staff, measureIndex: slot.measureIndex)
            }
            writes.append(microseconds(since: started) / Double(max(writeSlots.count, 1)))
        }
        report("write + effectiveMeasureDuration", median(writes))

        splitWriteAndRead(writeSlots: writeSlots, score: &score, repeats: repeats)
    }

    /// The split of `write + effectiveMeasureDuration` (S2, 2026-11-20): the write alone, the walk alone on the written
    /// slots' staves, and models of the two costs F9 adds to a write followed by a read — a box allocated per write
    /// (the old one freed), and two serial-queue locks around the read's miss and store (`SerialLock` is
    /// `DispatchQueue.sync` on Apple). The walk and the models run the same code against both commits.
    private static func splitWriteAndRead(writeSlots: [VoiceElementID], score: inout Score, repeats: Int) {
        let count = Double(max(writeSlots.count, 1))
        var writeOnly: [Double] = []
        for _ in 0 ..< repeats {
            let started = ContinuousClock.now
            for slot in writeSlots {
                rewrite(slot, in: &score)
            }
            writeOnly.append(microseconds(since: started) / count)
        }
        report("write only", median(writeOnly))

        let frozen = score
        var walkSink = 0
        var walks: [Double] = []
        for _ in 0 ..< repeats {
            let started = ContinuousClock.now
            for slot in writeSlots {
                let staff = frozen.parts[slot.staff.partIndex].staves[slot.staff.staffIndexInPart]
                walkSink &+= staff.measures.effectiveMeasureDurations().count
            }
            walks.append(microseconds(since: started) / count)
        }
        report("walk of the slot's staff (sink \(walkSink & 0xFF))", median(walks))

        let table = frozen.parts[0].staves[0].measures.effectiveMeasureDurations()
        let queue = DispatchQueue(label: "f9bench.model-lock")
        var holder = ModelBox()
        var boxes: [Double] = []
        for _ in 0 ..< repeats {
            let started = ContinuousClock.now
            for _ in writeSlots {
                holder = ModelBox()
            }
            boxes.append(microseconds(since: started) / count)
        }
        report("model: a box per write", median(boxes))

        var lockSink = 0
        var locks: [Double] = []
        for _ in 0 ..< repeats {
            let started = ContinuousClock.now
            for _ in writeSlots {
                let box = holder
                if queue.sync(execute: { box.durations }) == nil {
                    queue.sync { box.durations = table }
                }
                lockSink &+= box.durations?.count ?? 0
                box.durations = nil
            }
            locks.append(microseconds(since: started) / count)
        }
        report("model: miss + store under two locks (sink \(lockSink & 0xFF))", median(locks))

        var bothSink = 0
        var both: [Double] = []
        for _ in 0 ..< repeats {
            let started = ContinuousClock.now
            for _ in writeSlots {
                holder = ModelBox()
                let box = holder
                if queue.sync(execute: { box.durations }) == nil {
                    queue.sync { box.durations = table }
                }
                bothSink &+= box.durations?.count ?? 0
            }
            both.append(microseconds(since: started) / count)
        }
        report("model: box + two locks (sink \(bothSink & 0xFF))", median(both))
    }

    /// Every chord and rest (a rest is a chord without notes), in staff, measure, voice, element order.
    private static func chordsAndRests(of score: Score) -> [VoiceElementID] {
        var slots: [VoiceElementID] = []
        for (address, staff) in score.allStaves {
            for (measureIndex, measure) in staff.measures.enumerated() {
                for (voiceIndex, voice) in measure.voices.enumerated() {
                    for elementIndex in 0 ..< voice.elements.count {
                        guard case .chord = voice.elements[elementIndex] else { continue }
                        slots.append(VoiceElementID(
                            staff: address, measureIndex: measureIndex, voiceIndex: voiceIndex,
                            elementIndex: elementIndex,
                        ))
                    }
                }
            }
        }
        return slots
    }

    /// Writes the element at `slot` back unchanged, through the score's in-place path — a write the staff sees.
    private static func rewrite(_ slot: VoiceElementID, in score: inout Score) {
        score.parts.updateValue(at: slot.staff.partIndex) { part in
            part.staves.updateValue(at: slot.staff.staffIndexInPart) { staff in
                staff.measures[slot.measureIndex].voices[slot.voiceIndex].elements
                    .updateValue(at: slot.elementIndex) { element in
                        let same = element
                        element = same
                    }
            }
        }
    }

    /// Microseconds per call of `body` over every slot, the median of `repeats` rounds.
    private static func measure(
        _ name: String, slots: [VoiceElementID], repeats: Int, _ body: (VoiceElementID) -> Int,
    ) {
        var perCall: [Double] = []
        var sink = 0
        for _ in 0 ..< repeats {
            let started = ContinuousClock.now
            for slot in slots {
                sink &+= body(slot)
            }
            perCall.append(microseconds(since: started) / Double(max(slots.count, 1)))
        }
        report("\(name) (sink \(sink & 0xFF))", median(perCall))
    }

    private static func microseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1e6 + Double(elapsed.components.attoseconds) / 1e12
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    private static func report(_ name: String, _ microseconds: Double) {
        print(name.padding(toLength: 56, withPad: " ", startingAt: 0) + String(format: "%9.3f us/call", microseconds))
    }
}

/// The shape of F9's `StaffTimingCache`: one optional table behind a class reference.
private final class ModelBox: @unchecked Sendable {
    var durations: [Fraction]?
}
