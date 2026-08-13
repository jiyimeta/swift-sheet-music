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
import SheetMusicCore
import SheetMusicLayout
import SheetMusicMIDI

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

print("systems=\(document.systems.count) pages=\(pages.count) midi=\(bytes.count)B")
