import SheetMusicAudioCore

/// The main actor's side of the stretcher groups: making the pairs a group needs, the scratch they read through, and
/// the groups left draining after the track list dropped them. All of it is built before a lock section and handed over
/// inside it (`setRecordingTracks`, `setRate`).
extension SwiftySynthBackend {
    /// The groups to keep fading out, with where their state is in the render's array: every previous group with a
    /// pair that no new group carries on, and every group already draining whose fade-out is not over.
    ///
    /// The render's array holds the track list's groups (`recordingGroupLayout`) and then the draining ones
    /// (`drainingGroupLayout`). Which draining groups are silent is read in a lock section of its own, which allocates
    /// nothing; a draining group never plays again, so one found silent is still silent at the swap. A previous group
    /// of the track list is kept whether silent or not, since it may start sounding before the swap; if it is silent,
    /// the next call drops it.
    func drainingGroups(continued: Set<Int>) -> [(layout: RecordingGroupLayout, source: Int?)] {
        let liveCount = recordingGroupLayout.count
        var silent = [Bool](repeating: false, count: drainingGroupLayout.count)
        lock.withLockUnchecked { shared in
            for index in silent.indices where shared.alignment.groups.indices.contains(liveCount + index) {
                silent[index] = shared.alignment.groups[liveCount + index].state.isSilent
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

    /// Before a rate change reaches the render: pairs for the groups that need one at `rate` and lack it, with the
    /// scratch they need. `installStretchers` hands them over inside the lock section.
    func stretchersForRate() -> (pairs: [(group: Int, pair: StretcherPair)], scratch: StretchScratch?) {
        var layouts = recordingGroupLayout
        let capacity = makeMissingPairs(in: &layouts)
        var made: [(group: Int, pair: StretcherPair)] = []
        for index in layouts.indices where recordingGroupLayout[index].pair == nil {
            if let pair = layouts[index].pair { made.append((index, pair)) }
        }
        recordingGroupLayout = layouts
        return (made, stretchScratchIfNeeded(capacity: capacity))
    }

    /// Inside the lock: installs what `stretchersForRate` made. The swapped-out scratch comes back in `scratch`, to be
    /// released after the lock.
    nonisolated static func installStretchers(
        _ pairs: [(group: Int, pair: StretcherPair)], scratch: inout StretchScratch?, into shared: inout Shared,
    ) {
        for (group, pair) in pairs where shared.alignment.groups.indices.contains(group) {
            shared.alignment.groups[group].pair = pair
        }
        if scratch != nil { swap(&shared.alignment.stretchScratch, &scratch) }
    }
}
