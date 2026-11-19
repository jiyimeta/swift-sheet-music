import Foundation
import SheetMusicCore
import SheetMusicLoader

// F9 benchmark: the per-element timing questions a selection gate asks, over every chord and rest of a score.
//
//   swift run -c release F9Bench <score.mscz|.mscx> [repeats]
//
// Prints, per question, the median over `repeats` rounds of the microseconds one call took. Uses public API only, so
// the same source builds against the base commit and the branch.

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: F9Bench <score.mscz|.mscx> [repeats]")
    exit(2)
}

let repeats = arguments.count >= 3 ? Int(arguments[2]) ?? 5 : 5
var score = try ScoreLoader.loadScore(contentsOf: URL(fileURLWithPath: arguments[1]))

var slots: [VoiceElementID] = []
for (address, staff) in score.allStaves {
    for (measureIndex, measure) in staff.measures.enumerated() {
        for (voiceIndex, voice) in measure.voices.enumerated() {
            for (elementIndex, element) in voice.elements.enumerated() {
                switch element {
                case .chord, .rest:
                    slots.append(VoiceElementID(
                        staff: address, measureIndex: measureIndex, voiceIndex: voiceIndex,
                        elementIndex: elementIndex,
                    ))
                default:
                    break
                }
            }
        }
    }
}

let measureCount = score.allStaves.first?.staff.measures.count ?? 0
print("score: \(score.allStaves.count) staves, \(measureCount) measures, \(slots.count) chords and rests")

/// Microseconds per call of `body` over every slot, the median of `repeats` rounds.
func measure(_ name: String, _ body: (VoiceElementID) -> Int) {
    var perCall: [Double] = []
    var sink = 0
    for _ in 0 ..< repeats {
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for slot in slots {
                sink &+= body(slot)
            }
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        perCall.append(seconds * 1e6 / Double(max(slots.count, 1)))
    }
    perCall.sort()
    let median = perCall[perCall.count / 2]
    print(String(format: "%-34@ %9.3f us/call  (sink %d)", name as NSString, median, sink & 0xFF))
}

measure("effectiveMeasureDuration(at:)") { slot in
    score.effectiveMeasureDuration(at: slot.staff, measureIndex: slot.measureIndex).numerator
}

measure("resolveTickInMeasure(for:)") { slot in
    let rest = RestID(
        staff: slot.staff, measureIndex: slot.measureIndex, voiceIndex: slot.voiceIndex,
        elementIndex: slot.elementIndex,
    )
    return score.resolveTickInMeasure(for: .rest(rest)) ?? 0
}

measure("chronologicalBounds(of:)") { slot in
    score.chronologicalBounds(of: VoiceElementRange(start: slot, end: slot)) == nil ? 0 : 1
}

measure("voiceElements(in: one slot)") { slot in
    score.voiceElements(in: VoiceElementRange(start: slot, end: slot)).count
}

// A write, then a read: the cache is dropped every time, so this is the cost an edit loop pays. It must not get worse.
let writeSlots = Array(slots.prefix(500))
var writes: [Double] = []
for _ in 0 ..< repeats {
    let clock = ContinuousClock()
    let elapsed = clock.measure {
        for slot in writeSlots {
            let part = slot.staff.partIndex
            let staff = slot.staff.staffIndexInPart
            let voice = slot.voiceIndex
            let element = score.parts[part].staves[staff].measures[slot.measureIndex].voices[voice]
                .elements[slot.elementIndex]
            score.parts[part].staves[staff].measures[slot.measureIndex].voices[voice]
                .elements[slot.elementIndex] = element
            _ = score.effectiveMeasureDuration(at: slot.staff, measureIndex: slot.measureIndex)
        }
    }
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    writes.append(seconds * 1e6 / Double(max(writeSlots.count, 1)))
}

writes.sort()
print(String(format: "%-34@ %9.3f us/call", "write + effectiveMeasureDuration" as NSString, writes[writes.count / 2]))
