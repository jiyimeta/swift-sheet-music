import SheetMusicFoundation

/// MuseScore 4's dynamic levels (`framework/mpe/mpetypes.h:376-405`: pppppp 17.5 % … ffff 72.5 %, five points apart)
/// against the velocities this library plays (`Dynamic.defaultVelocity(for:)`, MuseScore's `dynList`): each ordinary
/// dynamic's velocity is its level, and a velocity between two of them the level between theirs, linearly. Levels are
/// in hundredths of a percent, MuseScore's own unit (`ONE_PERCENT = 100`). A ramp's velocities already carry the
/// instrument's velocity scale, which the levels step across unchanged — exact at the usual 100 %.
enum MuseScoreDynamicLevels {
    /// `DYNAMIC_LEVEL_STEP` (`mpetypes.h:379`): 5 %.
    static let step = 500.0

    private struct Point {
        let velocity: Double
        let level: Double
    }

    /// pppppp … ffff: the ordinary dynamics whose `dynList` velocities still differ (fffff and ffffff are 127 too).
    private static let table: [Point] = [
        Point(velocity: 1, level: 1750), Point(velocity: 5, level: 2250), Point(velocity: 10, level: 2750),
        Point(velocity: 16, level: 3250), Point(velocity: 33, level: 3750), Point(velocity: 49, level: 4250),
        Point(velocity: 64, level: 4750), Point(velocity: 80, level: 5250), Point(velocity: 96, level: 5750),
        Point(velocity: 112, level: 6250), Point(velocity: 126, level: 6750), Point(velocity: 127, level: 7250),
    ]

    static func level(ofVelocity velocity: Int) -> Double {
        let value = Double(velocity)
        guard let upper = table.firstIndex(where: { $0.velocity >= value }) else { return table[table.count - 1].level }
        guard upper > 0 else { return table[0].level }
        let below = table[upper - 1]
        let above = table[upper]
        return below.level + (value - below.velocity) / (above.velocity - below.velocity) * (above.level - below.level)
    }

    static func velocity(ofLevel level: Double) -> Int {
        guard let upper = table.firstIndex(where: { $0.level >= level }) else { return 127 }
        guard upper > 0 else { return 1 }
        let below = table[upper - 1]
        let above = table[upper]
        let fraction = (level - below.level) / (above.level - below.level)
        return Int((below.velocity + fraction * (above.velocity - below.velocity)).rounded())
    }

    /// The velocity one MuseScore 4 level above (`up`) or below `start`, within 1…127 — where a hairpin with no
    /// dynamic at its end in its direction arrives (`handleHairpin`, `playbackcontext.cpp:613-615`).
    static func oneStep(from start: Int, up: Bool) -> Int {
        let target = level(ofVelocity: start) + (up ? step : -step)
        return max(1, min(127, velocity(ofLevel: target)))
    }
}
