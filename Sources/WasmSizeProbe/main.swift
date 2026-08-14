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
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicEditWire
import SheetMusicLayout
import SheetMusicMIDI
import SheetMusicMSCX

let score = Score(
    division: 480,
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
