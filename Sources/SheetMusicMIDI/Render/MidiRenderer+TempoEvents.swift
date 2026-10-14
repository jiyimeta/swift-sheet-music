import SheetMusicCore
import SheetMusicFoundation

extension MidiRenderer {
    /// The first track's tempo metas for one plan entry. After a jump — an entry that does not continue the measure
    /// before it — the tempo in force at the target's downbeat, the notated one MuseScore's playback and the cursor
    /// play there, unless the sequence already stands at it or a point on that downbeat states it; then the measure's
    /// own points. `sequenceMicros` is the tempo the sequence stands at, carried from entry to entry.
    ///
    /// The re-statement is what MuseScore's export lacks: it writes only the map entries inside each repeat segment
    /// (`PauseMap::calculate`, `engraving/compat/midi/pausemap.cpp`), so its SMF keeps the previous segment's tempo
    /// until the next entry. Only a real difference adds an event, so a score MuseScore exports without drift exports
    /// the same here.
    static func tempoEvents(
        for entry: PlaybackEntry, jumped: Bool, tempoMap: ResolvedTempoMap, sequenceMicros: inout Int,
    ) -> [TimedMidiEvent] {
        var events: [TimedMidiEvent] = []
        let points = tempoMap.points(inMeasure: entry.measureIndex)
        if jumped, points.first?.tickInMeasure != 0 {
            let inForce = tempoMap.point(inForceAtMeasure: entry.measureIndex, tickInMeasure: 0)?
                .microsecondsPerQuarter ?? defaultMicrosPerQuarter
            if inForce != sequenceMicros {
                events.append(TimedMidiEvent(
                    tick: entry.tickOffset, event: .meta(.tempo(microsecondsPerQuarter: inForce)),
                ))
                sequenceMicros = inForce
            }
        }
        for point in points {
            events.append(TimedMidiEvent(
                tick: entry.tickOffset + point.tickInMeasure,
                event: .meta(.tempo(microsecondsPerQuarter: point.microsecondsPerQuarter)),
            ))
            sequenceMicros = point.microsecondsPerQuarter
        }
        return events
    }
}
