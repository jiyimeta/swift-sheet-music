/// A source tuplet as one target voice carries it (design §4.5): its ratio, how it is drawn, the ticks it spans and
/// the grid of members inside it. Every chord the voice holds inside the span starts on a member and is written at
/// that member's value; a member that receives no chord is a rest of its value.
struct RevoiceTupletUnit: Equatable {
    /// One chord or rest of the source tuplet: where it starts, how long it lasts and the value it is written as.
    struct Member: Equatable {
        let onset: Int
        let length: Int
        let duration: NoteDuration
    }

    let normalNotes: Int
    let actualNotes: Int
    let appearance: TupletAppearance
    let onset: Int
    let length: Int
    let members: [Member]

    var end: Int {
        onset + length
    }

    func contains(_ tick: Int) -> Bool {
        onset <= tick && tick < end
    }

    func overlaps(_ other: Self) -> Bool {
        onset < other.end && other.onset < end
    }

    /// The same span, ratio and member grid: what lets two source tuplets merge member by member. How each is drawn
    /// is not compared; the merged tuplet is drawn as the first.
    func hasSameGrid(as other: Self) -> Bool {
        onset == other.onset && length == other.length && normalNotes == other.normalNotes
            && actualNotes == other.actualNotes && members == other.members
    }

    /// The tuplet over slots `first ... last` of a written voice, drawn as its source is except for its side: as with
    /// a chord's stems (D3), the voice it now sits in decides, since a side a one-voice file forced would put voice
    /// 2's bracket into voice 1. It is always new: one source tuplet can be carried into two voices, and one
    /// identifier cannot be held by both.
    func slot(first: Int, last: Int) -> TupletSlot {
        var drawn = appearance
        drawn.direction = nil
        return TupletSlot(identity: .fresh, tuplet: Tuplet(
            normalNotes: normalNotes, actualNotes: actualNotes, startIndex: first, endIndex: last, appearance: drawn,
        ))
    }
}

/// One step of a rewritten voice's timeline: a tuplet the voice carries, as the voice's `index`-th unit, or a chord
/// outside every tuplet it carries.
enum RevoiceTimelinePiece {
    case tuplet(RevoiceTupletUnit, index: Int)
    case chord(RevoiceTargetChord)

    var onset: Int {
        switch self {
        case let .tuplet(unit, _): unit.onset
        case let .chord(chord): chord.onset
        }
    }
}

extension RevoiceBarPlanner {
    /// The tuplets one target voice carries, in onset order (design §4.5). A source tuplet is carried when one of
    /// its members sends a hit to this voice; one that sends nothing is ordinary time here. A carried tuplet's
    /// members must fill whole ticks; carried tuplets that overlap must share span, ratio and member grid, and then
    /// merge into one, drawn as the first in source order; every chord of the voice inside a carried tuplet must start
    /// on a member. Fails with `.tuplets` otherwise.
    static func tupletUnits(
        of chords: [RevoiceTargetChord], in bar: RevoiceBar, sources: SourceIndex,
    ) -> Result<[RevoiceTupletUnit], RevoiceKeepReason> {
        let carried = Set(chords.flatMap(\.incoming).compactMap { sources[$0.source]?.tuplet })
        var units: [RevoiceTupletUnit] = []
        for run in carried.sorted() {
            let unit = tupletUnit(ofRun: run, in: bar)
            guard fillsWholeTicks(unit, in: bar) else { return .failure(.tuplets) }
            guard let overlapping = units.first(where: { $0.overlaps(unit) }) else {
                units.append(unit)
                continue
            }
            guard overlapping.hasSameGrid(as: unit) else { return .failure(.tuplets) }
        }
        let startsOnMembers = chords.allSatisfy { chord in
            units.allSatisfy { unit in
                !unit.contains(chord.onset) || unit.members.contains { $0.onset == chord.onset }
            }
        }
        guard startsOnMembers else { return .failure(.tuplets) }
        return .success(units.sorted { $0.onset < $1.onset })
    }

    /// Source tuplet `run` of `bar` as a unit: its chords and rests are the members. The bar has no nested tuplets
    /// (`reasonToLeave`), so a chord's innermost tuplet is its only one.
    private static func tupletUnit(ofRun run: Int, in bar: RevoiceBar) -> RevoiceTupletUnit {
        let source = bar.tuplets[run]
        let members = bar.chords.filter { $0.tuplet == run }.map { member in
            RevoiceTupletUnit.Member(onset: member.onset, length: member.length, duration: member.chord.duration)
        }
        return RevoiceTupletUnit(
            normalNotes: source.tuplet.normalNotes, actualNotes: source.tuplet.actualNotes,
            appearance: source.tuplet.appearance, onset: source.onset, length: source.length, members: members,
        )
    }

    /// The members' ticks add up to the exact length of their values. A member's ticks are truncated, so a group
    /// whose values do not divide into whole ticks — seven sixteenths in the time of four are 68 4/7 ticks each at
    /// 480 per quarter — comes out short (476 for its quarter), and a voice written around it would be off by the
    /// difference: overfull, or short of the bar.
    private static func fillsWholeTicks(_ unit: RevoiceTupletUnit, in bar: RevoiceBar) -> Bool {
        let measure = Fraction(ticks: bar.meter.barTicks, division: bar.meter.division)
        let exact = unit.members.reduce(Fraction(numerator: 0, denominator: 1)) { total, member in
            total + member.duration.resolved(in: measure).asFraction
        }
        let scaled = exact.numerator * 4 * bar.meter.division
        let ticks = unit.members.reduce(0) { $0 + $1.length }
        return scaled % exact.denominator == 0 && scaled / exact.denominator == ticks
    }

    /// The voice's carried tuplets and the chords outside them, in onset order. A chord inside a tuplet is laid out
    /// as one of its members.
    static func timelinePieces(
        of chords: [RevoiceTargetChord], units: [RevoiceTupletUnit],
    ) -> [RevoiceTimelinePiece] {
        let outside = chords.filter { chord in !units.contains { $0.contains(chord.onset) } }
        let pieces = outside.map { RevoiceTimelinePiece.chord($0) }
            + units.enumerated().map { RevoiceTimelinePiece.tuplet($1, index: $0) }
        return pieces.sorted { $0.onset < $1.onset }
    }

    /// The slots of `unit`, the voice's `index`-th carried tuplet: one per member, holding the voice's chord that
    /// starts there at the member's value, or a rest of it. §4.2's extension never enters a tuplet. A chord whose
    /// length is heard (§4.4) must already last exactly its member; fails with the reason it cannot otherwise.
    static func memberSlots(
        of unit: RevoiceTupletUnit, index: Int, chords: [RevoiceTargetChord], voiceIndex: Int, sources: SourceIndex,
        landings: RevoiceLandings,
    ) -> Result<[RevoiceTimedSlot], RevoiceKeepReason> {
        var slots: [RevoiceTimedSlot] = []
        for member in unit.members {
            let chord = chords.first { $0.onset == member.onset }
            if let chord {
                switch chordLength(of: chord, voiceIndex: voiceIndex, sources: sources, landings: landings) {
                case let .failure(reason):
                    return .failure(reason)
                case let .success(.fixed(ticks, _, reason)):
                    guard ticks == member.length else { return .failure(reason) }
                case .success(.free):
                    break
                }
            }
            slots.append(RevoiceTimedSlot(
                onset: member.onset, duration: member.duration, chord: chord, tuplet: index,
            ))
        }
        return .success(slots)
    }
}
