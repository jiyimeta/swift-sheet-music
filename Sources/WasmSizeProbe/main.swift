// Linkable stand-in for a real WebAssembly host, used only by
// `Scripts/wasm-size.sh` to measure what the portable targets cost once
// compressed.
//
// It has to do actual work: a probe that merely imports the libraries lets the
// linker strip them and reports a number that means nothing. Laying out a score
// and rendering it to MIDI pulls in the layout engine, the engraving geometry
// and the MIDI writer.
//
// Only built when SWIFT_SHEET_MUSIC_WASM=1 is exported, so the normal package
// shape is unaffected.
import JavaScriptKit
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicEditWire
import SheetMusicLayout
import SheetMusicMIDI
import SheetMusicMSCX
import SheetMusicWasmBridge

/// Two measures with a repeat on the second, not a bare title frame. The
/// playback surface below is full of guards that return early on a score with no
/// measures and no repeat plan — an empty score would let the linker drop
/// `PlaybackClock`, the unroll map and the metronome sequence builder, and the
/// gate would then report a number for a graph the browser does not download.
let probeMeasures = [[60, 62, 64, 65], [67, 69, 71, 72]].enumerated().map { index, pitches in
    Measure(
        voices: [
            Voice(elements: pitches.map { pitch in
                .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: pitch, tpc: 14)])))
            }),
        ],
        startRepeat: index == 1,
        endRepeatCount: index == 1 ? 2 : nil,
    )
}

let score = Score(
    division: 480,
    parts: [
        Part(
            id: "1",
            instrument: Instrument(id: "piano", longName: "Piano"),
            staves: [Staff(measures: probeMeasures)],
        ),
    ],
    metaTags: ["workTitle": "size probe"],
    titleFrame: ScoreFrame(
        heightSp: 10,
        texts: [FrameText(style: .title, text: "size probe")],
    ),
)

let document = LayoutEngine.layout(
    score: score,
    options: ScoreViewOptions(),
    availableWidth: 800,
)
let pages = LayoutPaginator.paginate(
    systems: document.systems,
    pageHeight: 297,
    policy: .honor,
)
let midi = try MidiRenderer.render(score: score)
let bytes = try MidiWriter.write(midi)

// Round-trips through the container so the ZIP writer, the DEFLATE backend
// (the vendored zlib on wasm) and the whole MSCX decoder tree stay in the
// linked image. Without this the measurement covers layout and MIDI only,
// which is not what a browser host actually downloads.
let container = try MSCZWriter.write(score: score)
let reparsed = try MSCZReader.parse(container)

print("systems=\(document.systems.count) pages=\(pages.count) midi=\(bytes.count)B")
print("mscz=\(container.count)B parts=\(reparsed.parts.count)")

// The edit-intent codecs reach Wirelet, which imported the Foundation
// umbrella until 0.4.1 and was worth ~10 MB brotli on its own. Keeping the
// round trip here is what stops that coming back unnoticed.
let intentBytes = EditIntentCodec.encode(.composite([]))
let intent = try EditIntentCodec.decode(intentBytes)
print("intent=\(intentBytes.count)B \(intent)")

// The bridge layer itself, entered through the same calls the Android bridge makes,
// so what gets measured is what a browser host would actually ship rather than what
// merely links. `ScoreBridge.loadScore` drags in the format sniff and both parsers;
// `LayoutBridge.compute` runs the whole engraving pass and the draw-program encoder,
// which is the bulk of the target; `ScoreMetadataWire` keeps a Metadata/ wirelet codec
// in the image, since those are generated per directory and would otherwise go
// unmeasured.
let bridgeScore = try ScoreBridge.loadScore(bytes: container)
let program = LayoutBridge.compute(score: bridgeScore, pageWidthMM: 210, pageHeightMM: 297)
let decodedPages = try DrawProgramCodec.decode(program)
let handles = HandleTable<Score>()
let handle = handles.insert(bridgeScore)
let metadata = ScoreMetadataWire(title: "size probe", composer: "").encodeToData()
print(
    "bridge=\(program.count)B pages=\(decodedPages.count) "
        + "handle=\(handle) meta=\(metadata.count)B",
)

// The wasm bridge's own surface, entered through the same calls a browser host
// makes, so the gate measures what a page downloads rather than what merely
// links. `Scripts/wasm-size.sh` compresses this artifact and never runs it,
// which is what makes the calls safe: linking JavaScriptKit adds imports from
// the JS host, and those are unresolvable under wasmtime whether or not the code
// path executes. `WasmParityProbe`, which IS run under wasmtime, must therefore
// never depend on this target.
let wasmHandle = loadScore(bytes: JSUint8Array([UInt8](container)))
let wasmProgram = computeLayout(
    handle: wasmHandle,
    pageWidthMM: 210,
    pageHeightMM: 297,
    options: LayoutOptions(
        layoutMode: 0,
        staffSize: 28,
        honorLayoutBreaks: true,
        collapseMultiMeasureRests: false,
        showsInvisibleElements: false,
        showsLyrics: true,
        transposeSemitones: 0,
        hiddenStaves: [],
        clefOverrides: [],
    ),
)
let wasmBreaks = pageBreaks(handle: wasmHandle, pageHeightMM: 297)
let wasmMetadata = scoreMetadata(handle: wasmHandle)
let editHit = editingHitTest(handle: wasmHandle, xMM: 30, yMM: 40, activeVoice: 0)
let editCaret = editingCaretRect(
    handle: wasmHandle,
    kind: "note",
    partIndex: 0,
    staffIndexInPart: 0,
    measureIndex: 0,
    voiceIndex: 0,
    elementIndex: 0,
    noteIndexInChord: 0,
    minimumWidthMM: 1,
)
_ = installSMuFLMetrics(bytes: JSUint8Array(length: 0))
print(
    "wasm engine=\(engineVersionStamp()) handle=\(wasmHandle) "
        + "flat=\(wasmProgram.length)B breaks=\(wasmBreaks.count) "
        + "title=\(wasmMetadata?.title ?? "-") fp=\(scoreFingerprint(handle: wasmHandle))",
)
// The playback surface. `SheetMusicAudioCore` reaches the linked image only
// through these calls — nothing above touches `PlaybackTimeline`, the unroll map
// or the metronome sequence builder — so leaving them out would measure a graph
// the browser does not actually download.
let smf = renderMidi(handle: wasmHandle)
let clickSmf = renderMetronomeMidi(handle: wasmHandle)
let countInSmf = renderCountInMetronomeMidi(handle: wasmHandle, fromPlayerSeconds: 0)
let summary = playbackSummary(handle: wasmHandle)
let beats = metronomeBeats(handle: wasmHandle)
let cursor = cursorRectAtPlayerSeconds(handle: wasmHandle, playerSeconds: 0)
let measureRect = measureFrame(handle: wasmHandle, measureIndex: 0)
let loopSeconds = loopPlayerSeconds(
    handle: wasmHandle, fromMeasureIndex: 0, toMeasureExclusive: 1,
)
let loopRects = loopHighlightRects(
    handle: wasmHandle, fromMeasureIndex: 0, toMeasureExclusive: 1,
)
let tapSeconds = playerSecondsAtPoint(handle: wasmHandle, xMM: 30, yMM: 40)
let seekSeconds = playerSecondsForMeasure(handle: wasmHandle, measureIndex: 1)
let seekPositionSeconds = playerSecondsForPosition(
    handle: wasmHandle, measureIndex: 1, tickInMeasure: 480,
)
let seekPosition = positionAtPlayerSeconds(handle: wasmHandle, playerSeconds: seekPositionSeconds)
let atMeasure = measureIndexAtPlayerSeconds(handle: wasmHandle, playerSeconds: 0)
let preRoll = countInSeconds(handle: wasmHandle, fromPlayerSeconds: 0)
let markCount = rehearsalMarkCount(handle: wasmHandle)
let firstMark = rehearsalMark(handle: wasmHandle, index: 0)
let staffCount = staffDescriptorCount(handle: wasmHandle)
let firstStaff = staffDescriptor(handle: wasmHandle, index: 0)

// The mixer and its General MIDI table, which are the only paths that reach
// `LiveChannelPlan`'s labelling and `GMInstrument`.
let stripCount = mixerStripCount(handle: wasmHandle)
let firstStrip = mixerStrip(handle: wasmHandle, index: 0)
let gmNames = gmInstrumentNames()
let gmFamilies = gmInstrumentFamilies()
let tuning = masterTuningControlChanges(cents: -13)
let clickBank = buildClickSoundFont(strongWav: JSUint8Array(length: 0), weakWav: JSUint8Array(length: 0))

// The edit session lifecycle, scalar intent surface and bytes relay.
let editOpened = beginEditSession(handle: wasmHandle)
let editInitialState = editSessionState(handle: wasmHandle)
let editWriteRestOutcome = editWriteRest(
    handle: wasmHandle, partIndex: 0, staffIndexInPart: 0, measureIndex: 0,
    voiceIndex: 0, elementIndex: 0,
    durationKind: 3, durationNumerator: 0, durationDenominator: 0,
)
let editInputNoteOutcome = editInputNote(
    handle: wasmHandle, partIndex: 0, staffIndexInPart: 0, measureIndex: 0,
    voiceIndex: 0, elementIndex: 0, pitch: 60, tpc: 14,
    durationKind: 0, durationNumerator: 0, durationDenominator: 0,
)
let editSetRestDurationOutcome = editSetRestDuration(
    handle: wasmHandle, partIndex: 0, staffIndexInPart: 0, measureIndex: 1,
    voiceIndex: 0, elementIndex: 0,
    durationKind: 4, durationNumerator: 0, durationDenominator: 0,
)
let editSetChordDurationOutcome = editSetChordDuration(
    handle: wasmHandle, partIndex: 0, staffIndexInPart: 0, measureIndex: 0,
    voiceIndex: 0, elementIndex: 1,
    durationKind: 4, durationNumerator: 0, durationDenominator: 0,
)
let editWriteNoteOutcome = editWriteNote(
    handle: wasmHandle, partIndex: 0, staffIndexInPart: 0, measureIndex: 0,
    voiceIndex: 0, elementIndex: 1, pitch: 62, tpc: 16,
    durationKind: 5, durationNumerator: 0, durationDenominator: 0,
)
let editSetNotePitchOutcome = editSetNotePitch(
    handle: wasmHandle, partIndex: 0, staffIndexInPart: 0, measureIndex: 0,
    voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
    pitch: 64, tpc: 18, accidental: "",
)
let editSetAccidentalOutcome = editSetAccidental(
    handle: wasmHandle, partIndex: 0, staffIndexInPart: 0, measureIndex: 0,
    voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
    accidental: "accidentalSharp",
)
let editAddNoteOutcome = editAddNoteToChord(
    handle: wasmHandle, partIndex: 0, staffIndexInPart: 0, measureIndex: 0,
    voiceIndex: 0, elementIndex: 1, pitch: 67, tpc: 15, accidental: "",
)
let editRemoveNoteOutcome = editRemoveNoteFromChord(
    handle: wasmHandle, partIndex: 0, staffIndexInPart: 0, measureIndex: 0,
    voiceIndex: 0, elementIndex: 1, noteIndexInChord: 1,
)
let editSetTieOutcome = editSetTie(
    handle: wasmHandle,
    fromPartIndex: 0, fromStaffIndexInPart: 0, fromMeasureIndex: 0,
    fromVoiceIndex: 0, fromElementIndex: 1, fromNoteIndexInChord: 0,
    toPartIndex: 0, toStaffIndexInPart: 0, toMeasureIndex: 0,
    toVoiceIndex: 0, toElementIndex: 2, toNoteIndexInChord: 0,
    hasSourceTieForward: 1, sourceTieForward: 1,
    hasTargetTieBack: 1, targetTieBack: 1,
)
let editCreateTupletOutcome = editCreateTuplet(
    handle: wasmHandle, partIndex: 0, staffIndexInPart: 0, measureIndex: 1,
    voiceIndex: 0, elementIndex: 1, actualNotes: 3, normalNotes: 2,
)
let editRemoveTupletOutcome = editRemoveTuplet(
    handle: wasmHandle, partIndex: 0, staffIndexInPart: 0, measureIndex: 1,
    voiceIndex: 0, elementIndex: 1,
)
let editDeleteOutcome = editDelete(
    handle: wasmHandle, partIndex: 0, staffIndexInPart: 0, measureIndex: 0,
    voiceIndex: 0, elementIndex: 3,
)
let editIntentBytes = EditIntentCodec.encode(.composite([]))
let editBytesOutcome = applyEditIntentBytes(handle: wasmHandle, intentBytes: JSUint8Array([UInt8](editIntentBytes)))
let editUndoOutcome = editUndo(handle: wasmHandle)
let editRedoOutcome = editRedo(handle: wasmHandle)
endEditSession(handle: wasmHandle)

// Split across several statements on purpose: one interpolation with a dozen
// operands is enough to time out the type checker.
print("playback smf=\(smf.length)B click=\(clickSmf.length)B countIn=\(countInSmf.length)B")
print("playback measures=\(summary?.measureCount ?? -1) beats=\(beats.count)")
print("playback cursorY=\(cursor?.yMM ?? -1) loop=\(loopSeconds.count) rects=\(loopRects.count)")
print(
    "playback tap=\(tapSeconds) seek=\(seekSeconds) "
        + "posSeek=\(seekPositionSeconds) pos=\(seekPosition.count) "
        + "at=\(atMeasure) preRoll=\(preRoll)",
)
print(
    "score marks=\(markCount) firstMark=\(firstMark?.text ?? "-") "
        + "staves=\(staffCount) firstStaff=\(firstStaff?.defaultClefRawType ?? "-") "
        + "measureRect=\(measureRect.count)",
)
print("edit geometry hit=\(editHit?.kind ?? "-") caret=\(editCaret?.heightMM ?? -1)")
print("mixer strips=\(stripCount) first=\(firstStrip?.displayName ?? "-")")
print("mixer gm=\(gmNames.count)/\(gmFamilies.count) tuning=\(tuning.count) click=\(clickBank.length)B")
print(
    "edit open=\(editOpened) active=\(editInitialState.active) "
        + "bytes=\(editBytesOutcome.accepted) undo=\(editUndoOutcome.code) redo=\(editRedoOutcome.code)",
)
print(
    "edit scalars input=\(editInputNoteOutcome.accepted) rest=\(editSetRestDurationOutcome.accepted) "
        + "chord=\(editSetChordDurationOutcome.accepted) delete=\(editDeleteOutcome.accepted)",
)
print(
    "edit notes writeRest=\(editWriteRestOutcome.accepted) writeNote=\(editWriteNoteOutcome.accepted) "
        + "pitch=\(editSetNotePitchOutcome.accepted) accidental=\(editSetAccidentalOutcome.accepted)",
)
print(
    "edit chord add=\(editAddNoteOutcome.accepted) remove=\(editRemoveNoteOutcome.accepted) "
        + "tie=\(editSetTieOutcome.accepted) tuplet=\(editCreateTupletOutcome.accepted)/"
        + "\(editRemoveTupletOutcome.accepted)",
)

releaseScore(handle: wasmHandle)
