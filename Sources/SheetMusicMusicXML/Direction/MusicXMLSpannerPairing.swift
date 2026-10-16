import SheetMusicCore
import SheetMusicFoundation

/// One open-spanner slot of a part: MuseScore keeps one per (family, number) for the whole part
/// (`MusicXmlParserPass2::getSpanner`, `P2:5544-5557`) — hairpins and ottavas by `number`, brackets and dashes sharing
/// the `line` family, one pedal slot. `number` is 0-based and below `maximumNumber`.
struct MusicXMLSpannerSlot: Sendable, Hashable {
    enum Family: Sendable, Hashable {
        case hairpin
        case ottava
        case pedal
        case line
    }

    /// `MAX_NUMBER_LEVEL` (`shared/musicxmltypes.h`).
    static let maximumNumber = 16

    let family: Family
    let number: Int

    /// A direction-type child's `number` as MuseScore reads it (`directionType`, `P2:4024-4033`): absent → 0; a
    /// positive one made 0-based; 0, or text that is no number (`String::toInt` reads it as 0), stays 0. `nil` when
    /// no slot takes it — a negative number, or one past `MAX_NUMBER_LEVEL` (`getSpanner` hands out a dummy slot).
    static func number(_ attribute: String?) -> Int? {
        guard let attribute, !attribute.isEmpty else { return 0 }
        let parsed = Int(attribute) ?? 0
        let number = parsed > 0 ? parsed - 1 : parsed
        return (0 ..< maximumNumber).contains(number) ? number : nil
    }
}

/// What a stop element changes on the spanner it closes, as data so that an event's equality is real. A wedge's and an
/// ottava's stop change nothing; a pedal's carries its `Change` (`MusicXMLDirectionDecoder+Pedal.swift`).
struct MusicXMLSpannerStopEdit: Sendable, Equatable {
    enum Change: Sendable, Equatable {
        /// `<pedal type="stop|discontinue">` (`P2:5410-5422`): its `line` attribute and its resolved `sign`.
        case pedalStop(discontinue: Bool, line: String?, sign: String)
        /// The stop half of `<pedal type="change">` (`P2:5426-5434`), which ends the open pedal with a 45° hook.
        case pedalChange(line: String?)
    }

    var change: Change?

    init(_ change: Change? = nil) {
        self.change = change
    }

    /// A stop MuseScore makes only against an open spanner, never held for a start to come: a pedal change's stop
    /// half (`P2:5426-5437`).
    var closesOnlyAnOpenStart: Bool {
        if case .pedalChange = change { return true }
        return false
    }

    /// Applies the stop's changes to the begin side. `stopCameFirst` is the order MuseScore saw them in: a stop with
    /// nothing open edits a fresh element that the later start takes over and rewrites (`P2:5389`, `5411`), so only
    /// what the start leaves alone survives of it.
    func apply(_ spanner: inout Spanner, stopCameFirst: Bool = false) {
        change?.apply(&spanner, stopCameFirst: stopCameFirst)
    }
}

/// A start and a stop paired: the begin side (carrying `<next>`) and the payload-less end marker, each a
/// `.voice(.spanner(…))` event at the site that contains it.
struct MusicXMLClosedSpanner: Sendable, Equatable {
    let begin: MusicXMLDirectionEvent
    let end: MusicXMLDirectionEvent
    /// Both sides land on the same (measure, staff, tick): the begin is written before its own end.
    let isZeroLength: Bool
}

/// Pairs a part's `.spannerStart` / `.spannerStop` events by slot (`MusicXmlParserDirection::direction`,
/// `P2:3777-3839`) and computes the begin side's `<next>` by the writer's rule (`connectorinfowriter.cpp:82-96`;
/// `Spanner+Offsets.swift`).
enum MusicXMLSpannerPairing {
    /// A (measure, tick) position moved to the measure that CONTAINS it: a tick on or past a bar line belongs to the
    /// next measure (`MeasureBaseList::measureByTick`, `measurebase.cpp:943-970`), the last measure keeping whatever
    /// is left, as MuseScore's own lookup does at the score's end.
    static func roll(
        measure: Int, tick: Fraction, measureLengths: [Fraction],
    ) -> (measure: Int, tick: Fraction) {
        var measure = measure
        var tick = tick
        while measure >= 0, measure < measureLengths.count - 1, !tick.precedes(measureLengths[measure]) {
            tick -= measureLengths[measure]
            measure += 1
        }
        return (measure, tick)
    }

    /// `(measures, fractions)` of a `<next>` — the stop's measure minus the start's, the stop's offset in its
    /// measure minus the start's (omitted when zero); `nil` when the stop precedes the start.
    static func offsets(
        fromMeasure: Int, fromTick: Fraction, toMeasure: Int, toTick: Fraction, measureLengths: [Fraction],
    ) -> (measures: Int, fractions: Fraction?)? {
        let start = roll(measure: fromMeasure, tick: fromTick, measureLengths: measureLengths)
        let end = roll(measure: toMeasure, tick: toTick, measureLengths: measureLengths)
        if end.measure < start.measure || (end.measure == start.measure && end.tick.precedes(start.tick)) {
            return nil
        }
        let delta = end.tick - start.tick
        return (end.measure - start.measure, delta.isZeroTick ? nil : delta)
    }

    /// Walks the events once, in file order. A start in an open slot is ignored (`P2:3812-3815`) — except a pedal's,
    /// which drops the open pedal and opens in its place, as MuseScore deletes an unterminated pedal as an unrecorded
    /// "discontinue", unless the open one began a change (`P2:5360-5388`). Otherwise a start closes against a stop the
    /// slot holds (`P2:3827-3833`), or opens the slot. A stop closes the slot's open start, or is held until the start
    /// comes (`P2:3799-3805`) unless the slot holds one already (`P2:3781-3783`) or it is a pedal change's
    /// (`closesOnlyAnOpenStart`). Whatever is open or held at the end is dropped, as MuseScore deletes it at the part's
    /// end (`P2:2318-2341`).
    static func pairClosed(
        _ events: [MusicXMLDirectionEvent], measureLengths: [Fraction],
    ) -> [MusicXMLClosedSpanner] {
        var open: [MusicXMLSpannerSlot: (spanner: Spanner, event: MusicXMLDirectionEvent)] = [:]
        var held: [MusicXMLSpannerSlot: (edit: MusicXMLSpannerStopEdit, event: MusicXMLDirectionEvent)] = [:]
        var result: [MusicXMLClosedSpanner] = []
        for event in events {
            switch event.payload {
            case let .spannerStart(slot, spanner):
                if let current = open[slot] {
                    if replacesOpenStart(current.spanner, slot: slot) { open[slot] = (spanner, event) }
                    continue
                }
                if let stop = held.removeValue(forKey: slot) {
                    let pair = closed(
                        spanner, begin: event, end: stop.event, measureLengths: measureLengths, edit: stop.edit,
                        stopCameFirst: true,
                    )
                    if let pair { result.append(pair) }
                } else {
                    open[slot] = (spanner, event)
                }
            case let .spannerStop(slot, edit):
                if let start = open.removeValue(forKey: slot) {
                    let pair = closed(
                        start.spanner, begin: start.event, end: event, measureLengths: measureLengths, edit: edit,
                    )
                    if let pair { result.append(pair) }
                } else if held[slot] == nil, !edit.closesOnlyAnOpenStart {
                    held[slot] = (edit, event)
                }
            case .voice:
                continue
            }
        }
        return result
    }

    /// Whether a start replaces the spanner open in its slot: only a pedal's, and not over a change pedal (begin hook
    /// 45°), whose follower MuseScore drops as "already started" (`P2:5364-5382`, `3813-3815`).
    private static func replacesOpenStart(_ open: Spanner, slot: MusicXMLSpannerSlot) -> Bool {
        slot.family == .pedal && open.lineProperties?.beginHook != .hook45
    }

    /// The pair as a begin side at the start's rolled site, carrying `<next>` and the stop's edit, and an end marker
    /// at the stop's rolled site, each on the staff of its own direction; `nil` when the stop precedes the start.
    /// The begin side is `isEndMarker: false` explicitly — a hidden one (`visible: false`) would otherwise derive
    /// `true` (`Spanner.init`). `stopCameFirst` says the stop was read before its start (`MusicXMLSpannerStopEdit`).
    static func closed(
        _ spanner: Spanner, begin: MusicXMLDirectionEvent, end: MusicXMLDirectionEvent, measureLengths: [Fraction],
        edit: MusicXMLSpannerStopEdit, stopCameFirst: Bool = false,
    ) -> MusicXMLClosedSpanner? {
        guard let next = offsets(
            fromMeasure: begin.measure, fromTick: begin.tick, toMeasure: end.measure, toTick: end.tick,
            measureLengths: measureLengths,
        ) else { return nil }
        var side = spanner
        side.isEndMarker = false
        side.nextMeasuresOffset = next.measures
        side.nextFractionsOffset = next.fractions
        edit.apply(&side, stopCameFirst: stopCameFirst)
        var marker = Spanner(kind: side.kind, rawType: side.rawType, visible: false)
        marker.chordTextLine = side.chordTextLine
        let from = roll(measure: begin.measure, tick: begin.tick, measureLengths: measureLengths)
        let to = roll(measure: end.measure, tick: end.tick, measureLengths: measureLengths)
        return MusicXMLClosedSpanner(
            begin: MusicXMLDirectionEvent(
                measure: from.measure, staff: begin.staff, tick: from.tick, payload: .voice(.spanner(side)),
            ),
            end: MusicXMLDirectionEvent(
                measure: to.measure, staff: end.staff, tick: to.tick, payload: .voice(.spanner(marker)),
            ),
            isZeroLength: from.measure == to.measure && begin.staff == end.staff && from.tick == to.tick,
        )
    }

    /// One queue, sorted stably by (measure, staff, tick, class): the end of a spanner that has length (class 0), then
    /// any begin (class 1), then the end of a zero-length spanner (class 2). MuseScore writes a segment's spanners by
    /// spanner, begin before end (`twrite.cpp:3562-3592`), so a chained pair stops one before it starts the next
    /// while a zero-length one stays begin-then-end. The splicer keeps this order on a shared tick.
    static func ordered(_ closed: [MusicXMLClosedSpanner]) -> [MusicXMLDirectionEvent] {
        var items: [Ranked] = []
        for spanner in closed {
            items.append(Ranked(event: spanner.begin, rank: 1, index: items.count))
            items.append(Ranked(event: spanner.end, rank: spanner.isZeroLength ? 2 : 0, index: items.count))
        }
        return items.sorted { $0.precedes($1) }.map(\.event)
    }

    /// The part's spanner events, paired and ordered.
    static func pair(_ events: [MusicXMLDirectionEvent], measureLengths: [Fraction]) -> [MusicXMLDirectionEvent] {
        ordered(pairClosed(events, measureLengths: measureLengths))
    }

    private struct Ranked {
        let event: MusicXMLDirectionEvent
        let rank: Int
        let index: Int

        func precedes(_ other: Ranked) -> Bool {
            if event.measure != other.event.measure { return event.measure < other.event.measure }
            if event.staff != other.event.staff { return event.staff < other.event.staff }
            if event.tick != other.event.tick { return event.tick.precedes(other.event.tick) }
            if rank != other.rank { return rank < other.rank }
            return index < other.index
        }
    }
}
