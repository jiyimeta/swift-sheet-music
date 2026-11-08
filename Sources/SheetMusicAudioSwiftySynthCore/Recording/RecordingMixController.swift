import SheetMusicAudioCore

/// The control side of a SwiftySynth host's recordings: grouping the tracks, making the stretcher pairs a group needs,
/// the scratch they read through, and the groups left draining after the track list dropped them. All of it is built
/// before a lock section and handed over inside it — the Apple backend's (`SwiftySynthBackend`) and Android's
/// (`HostedSynth`) alike, each passing its own lock as `withAlignment`.
///
/// Not thread-safe: its host makes every call on one actor or under a lock of its own, never on the render thread.
/// `withAlignment` runs its body with the render state under the render lock; nothing here allocates inside it, and
/// what it swaps out comes back to be released after it.
package final class RecordingMixController {
    /// Runs its body on the render's alignment state, under the lock the render thread takes.
    package typealias WithAlignment = ((inout PlaybackAlignmentState) -> Void) -> Void

    let sampleRate: Double
    /// What makes the stretchers recordings are read through when the rate is not 100 % or a track is transposed. Nil:
    /// recordings are read directly at any rate (varispeed) and their transposition is ignored.
    package var stretcherFactory: RecordingStretcherFactory?
    /// The host's rate, which decides which groups need a stretcher. The host sets it before `stretchersForRate()`.
    package var rate: Float = 1
    /// The control side's copy of the render's groups' layout and pairs.
    var recordingGroupLayout: [RecordingGroupLayout] = []
    /// The control side's copy of the groups left draining after the track list dropped them; in the render's array
    /// they follow `recordingGroupLayout`'s.
    var drainingGroupLayout: [RecordingGroupLayout] = []
    /// The input capacity of the stretch scratch handed to the render thread, 0 before the first.
    var stretchScratchCapacity = 0
    /// The track list (`setRecordingTracks`) and the tables of a track's own
    /// (`setPlaybackAlignment(warp:segments:trackSegments:withAlignment:)`) last handed over. A track's table decides
    /// its group, so each call reads the other's latest. A new track list groups the tracks again
    /// (`installRecordingTracks`); new tables that keep the grouping are swapped into their groups in place
    /// (`swapTablesInPlace`), and only tables that regroup the tracks group them again.
    package private(set) var recordingTracks: [RecordingTrackRender] = []
    package private(set) var recordingTrackSegments: [String: [RecordingSegment]] = [:]

    package init(sampleRate: Double, stretcherFactory: RecordingStretcherFactory?) {
        self.sampleRate = sampleRate
        self.stretcherFactory = stretcherFactory
    }

    // MARK: Tracks and tables

    /// Replaces the recordings in one lock section, grouped by transposition and table with the tables of a track's
    /// own last set (`setPlaybackAlignment(warp:segments:trackSegments:withAlignment:)`). A track whose `id` was
    /// already playing keeps its playhead and its gain ramp, so a new gain neither fades nor jumps it: the render ramps
    /// to it over the fade. A group carries on the stretchers of the previous group that held most of its tracks
    /// (`RecordingGroupPlan`); when its transposition or its tracks changed, or a track's file or offset, the render
    /// restarts it, primed and retuned, and crossfades. A new table alone does not restart it: the render follows the
    /// table, jumping only where the group's target moves. A previous group nobody carries on is kept draining
    /// until its fade-out is over, and dropped by the first call after that. Stretchers a group now needs are made
    /// here, off the render thread. The previous arrays, stretchers and scratch are released after the lock, never on
    /// the render thread.
    package func setRecordingTracks(_ tracks: [RecordingTrackRender], withAlignment: WithAlignment) {
        recordingTracks = tracks
        installRecordingTracks(tables: nil, withAlignment: withAlignment)
    }

    /// Swaps the speed table and the schedule together in one lock section: the next render call sees either the old
    /// pair or the new one, and the transport takes the new speed from its next block — no stop, seek or reload. A
    /// track keyed in `trackSegments` plays its table at offset 0, every other track `segments` at its offset. Each
    /// group's table is laid out here, and the render reads it from the group without looking anything up.
    ///
    /// New tables that keep the grouping — a host dragging a track's placement pushes one per pointer event — are
    /// swapped into their groups in place, in the lock section that swaps the speed table and the schedule, and
    /// restart nothing: a group's stretcher jumps only where its target moves, as under a new shared table
    /// (`swapTablesInPlace`). A track's table decides its group, so tables that regroup the tracks group them again
    /// and hand the groups over in that one lock section instead; a group whose tracks changed restarts.
    package func setPlaybackAlignment(
        warp: PlaybackTimeWarp?, segments: [RecordingSegment], trackSegments: [String: [RecordingSegment]],
        withAlignment: WithAlignment,
    ) {
        var tables = AlignmentTables(
            speedTable: TransportSpeedTable(warp: warp), schedule: RecordingSchedule(segments: segments),
        )
        guard trackSegments == recordingTrackSegments else {
            let swapped = swapTablesInPlace(trackSegments, tables: tables, withAlignment: withAlignment)
            recordingTrackSegments = trackSegments
            if !swapped { installRecordingTracks(tables: tables, withAlignment: withAlignment) }
            return
        }
        withAlignment { alignment in
            tables.swap(into: &alignment)
        }
    }

    /// Groups `recordingTracks` by transposition and by the table each has of its own in `recordingTrackSegments`,
    /// and hands the tracks and the groups over in one lock section, with `tables` too when a new alignment brought
    /// them (`setRecordingTracks` has the rules a group follows across a call).
    func installRecordingTracks(tables: AlignmentTables?, withAlignment: WithAlignment) {
        let reading = recordingTracksAsRead()
        let tracks = reading.tracks
        var incoming = tracks.map { RenderedRecording($0) }
        let plan = RecordingGroupPlan.make(tracks: tracks, tables: reading.tables, previous: recordingGroupLayout)
        var layouts = plan.map { group in
            RecordingGroupLayout(
                transposeSemitones: group.transposeSemitones, segments: group.segments,
                tracks: group.trackIndices.map { tracks[$0] },
                pair: group.continues.flatMap { recordingGroupLayout[$0].pair },
            )
        }
        var scratch = stretchScratchIfNeeded(capacity: makeMissingPairs(in: &layouts))
        let draining = drainingGroups(continued: Set(plan.compactMap(\.continues)), withAlignment: withAlignment)
        var groups = plan.indices.map { index in
            RecordingStretchGroup(layout: layouts[index], trackIndices: plan[index].trackIndices)
        } + draining.map { drain in
            RecordingStretchGroup(
                layout: drain.layout, trackIndices: Array(drain.layout.tracks.indices),
                drainTracks: drain.layout.tracks.map { RenderedRecording($0) },
            )
        }
        // Where each new group's render state comes from in the array being replaced, and whether it restarts.
        let sources = plan.map(\.continues) + draining.map(\.source)
        let restarts = plan.map(\.restarts) + draining.map { _ in false }
        var tables = tables
        withAlignment { alignment in
            for index in incoming.indices {
                let id = incoming[index].id
                if let playing = alignment.tracks.first(where: { $0.id == id }) {
                    incoming[index].playhead = playing.playhead
                    incoming[index].gainRamp = playing.gainRamp
                }
            }
            for index in groups.indices {
                guard let source = sources[index], alignment.groups.indices.contains(source) else { continue }
                groups[index].state = alignment.groups[source].state
                if restarts[index] { groups[index].state.needsRestart = true }
            }
            swap(&alignment.tracks, &incoming)
            swap(&alignment.groups, &groups)
            if scratch != nil { swap(&alignment.stretchScratch, &scratch) }
            tables?.swap(into: &alignment)
        }
        recordingGroupLayout = layouts
        drainingGroupLayout = draining.map(\.layout)
    }

    /// Swaps each group's table for the one `trackSegments` gives it, when that keeps the grouping as it is: the same
    /// groups of the same tracks at the same transpositions, each still on a table of its own or still on the shared
    /// one, so no track's offset changes either. In one lock section with `tables`, and without a restart: the render
    /// follows the new tables as it follows a new shared one, jumping only where a group's target moves. Returns false,
    /// having changed nothing, when the tracks must be grouped again instead (`installRecordingTracks`). Draining
    /// groups are left as they are: they no longer play.
    func swapTablesInPlace(
        _ trackSegments: [String: [RecordingSegment]], tables: AlignmentTables, withAlignment: WithAlignment,
    ) -> Bool {
        let parts = RecordingGroupPlan.partition(
            tracks: recordingTracks, tables: recordingTracks.map { trackSegments[$0.id] },
        )
        guard parts.count == recordingGroupLayout.count else { return false }
        for (layout, part) in zip(recordingGroupLayout, parts) {
            guard layout.transposeSemitones == part.transposeSemitones,
                  layout.trackIDs == part.trackIndices.map({ recordingTracks[$0].id }),
                  (layout.segments == nil) == (part.segments == nil)
            else { return false }
        }
        var schedules = parts.map { part in part.segments.map { RecordingSchedule(segments: $0) } }
        var tables = tables
        withAlignment { alignment in
            // The live groups come first in the render's array, in `recordingGroupLayout`'s order.
            for index in schedules.indices where alignment.groups.indices.contains(index) {
                swap(&alignment.groups[index].schedule, &schedules[index])
            }
            tables.swap(into: &alignment)
        }
        for index in recordingGroupLayout.indices {
            recordingGroupLayout[index].segments = parts[index].segments
        }
        return true
    }

    /// The track list as the render reads it, with each track's table of its own (nil: the shared one). A track with
    /// one reads its file at that table's seconds, which are the file's own, so it is handed over at offset 0.
    func recordingTracksAsRead() -> (tracks: [RecordingTrackRender], tables: [[RecordingSegment]?]) {
        let tables = recordingTracks.map { recordingTrackSegments[$0.id] }
        let tracks = zip(recordingTracks, tables).map { track, table in
            var read = track
            if table != nil { read.offsetSeconds = 0 }
            return read
        }
        return (tracks, tables)
    }

    /// The groups to keep fading out, with where their state is in the render's array: every previous group with a
    /// pair that no new group carries on, and every group already draining whose fade-out is not over.
    ///
    /// The render's array holds the track list's groups (`recordingGroupLayout`) and then the draining ones
    /// (`drainingGroupLayout`). Which draining groups are silent is read in a lock section of its own, which allocates
    /// nothing; a draining group never plays again, so one found silent is still silent at the swap. A previous group
    /// of the track list is kept whether silent or not, since it may start sounding before the swap; if it is silent,
    /// the next call drops it.
    func drainingGroups(
        continued: Set<Int>, withAlignment: WithAlignment,
    ) -> [(layout: RecordingGroupLayout, source: Int?)] {
        let liveCount = recordingGroupLayout.count
        var silent = [Bool](repeating: false, count: drainingGroupLayout.count)
        withAlignment { alignment in
            for index in silent.indices where alignment.groups.indices.contains(liveCount + index) {
                silent[index] = alignment.groups[liveCount + index].state.isSilent
            }
        }
        var draining: [(layout: RecordingGroupLayout, source: Int?)] = []
        for index in recordingGroupLayout.indices where recordingGroupLayout[index].pair != nil {
            if !continued.contains(index) { draining.append((recordingGroupLayout[index], index)) }
        }
        for index in drainingGroupLayout.indices where !silent[index] {
            draining.append((drainingGroupLayout[index], liveCount + index))
        }
        return draining
    }

    // MARK: Stretchers

    /// Whether a group of this transposition is read through a stretcher at the current rate.
    func needsStretcher(transposeSemitones: Double) -> Bool {
        rate != 1 || transposeSemitones != 0
    }

    /// Gives every group that needs a stretcher and has none a new pair from the factory (none without a factory), and
    /// returns the scratch input capacity the new pairs need. Only a new pair is asked: one already handed to the
    /// render thread is the render thread's to call.
    func makeMissingPairs(in layouts: inout [RecordingGroupLayout]) -> Int {
        guard let stretcherFactory else { return 0 }
        var capacity = 0
        for index in layouts.indices where layouts[index].pair == nil {
            guard needsStretcher(transposeSemitones: layouts[index].transposeSemitones) else { continue }
            let pair = StretcherPair(factory: stretcherFactory, sampleRate: sampleRate)
            capacity = max(capacity, StretchScratch.inputCapacity(for: pair.first))
            layouts[index].pair = pair
        }
        return capacity
    }

    /// A scratch of `capacity` when the installed one is smaller; nil when it is big enough.
    func stretchScratchIfNeeded(capacity: Int) -> StretchScratch? {
        guard capacity > stretchScratchCapacity else { return nil }
        stretchScratchCapacity = capacity
        return StretchScratch(inputCapacity: capacity)
    }

    /// What a rate change needs before it reaches the render: the pairs for the groups that need one at `rate` and
    /// lack it, with the scratch they need. The host installs them in the lock section that sets the rate
    /// (`StretchersForRate.install(into:)`).
    package func stretchersForRate() -> StretchersForRate {
        var layouts = recordingGroupLayout
        let capacity = makeMissingPairs(in: &layouts)
        var made: [(group: Int, pair: StretcherPair)] = []
        for index in layouts.indices where recordingGroupLayout[index].pair == nil {
            if let pair = layouts[index].pair { made.append((index, pair)) }
        }
        recordingGroupLayout = layouts
        return StretchersForRate(pairs: made, scratch: stretchScratchIfNeeded(capacity: capacity))
    }
}

/// The stretchers a rate change made (`RecordingMixController.stretchersForRate()`), to be handed to the render.
package struct StretchersForRate {
    let pairs: [(group: Int, pair: StretcherPair)]
    /// The new scratch going in, then the one it replaced coming back out, to be released after the lock.
    var scratch: StretchScratch?

    /// Inside the lock: installs the pairs and the scratch. The swapped-out scratch stays here, to be released after
    /// the lock.
    package mutating func install(into alignment: inout PlaybackAlignmentState) {
        for (group, pair) in pairs where alignment.groups.indices.contains(group) {
            alignment.groups[group].pair = pair
        }
        if scratch != nil { swap(&alignment.stretchScratch, &scratch) }
    }
}
