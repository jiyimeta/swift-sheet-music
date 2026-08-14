// Parses a score file and prints a digest of the result, so the same input
// can be run natively and under a WebAssembly host and the two answers
// compared byte for byte.
//
// This is the gate for the vendored zlib in `Sources/zlib`: `.mscz` is a ZIP
// of DEFLATE-compressed entries, so if the WebAssembly build's inflate
// disagreed with the platform one — even by a byte — the parsed score would
// differ and `stableFingerprint` would diverge. The fingerprint is FNV-1a
// with fixed constants and no per-process seed, which is what makes it
// comparable across two separately linked images at all.
//
// The counts are printed alongside it so a mismatch says something about
// where it went wrong rather than just that it did.
//
// Usage:
//   swift run WasmParityProbe <path.mscz|path.mscx>
//   wasmtime --dir . WasmParityProbe.wasm <path.mscz|path.mscx>
//
// Only built when SWIFT_SHEET_MUSIC_WASM=1 is exported.
import SheetMusicCore
import SheetMusicFoundation
import SheetMusicMSCX

guard CommandLine.arguments.count == 2 else {
    print("usage: WasmParityProbe <path.mscz|path.mscx>")
    exit(2)
}

let path = CommandLine.arguments[1]
let data: Data
do {
    data = try Data(contentsOf: URL(fileURLWithPath: path))
} catch {
    print("error: cannot read \(path): \(error)")
    exit(1)
}

let score: Score
do {
    score = if path.hasSuffix(".mscz") {
        try MSCZReader.parse(data)
    } else {
        try MSCXParser.parse(data)
    }
} catch {
    print("error: cannot parse \(path): \(error)")
    exit(1)
}

let staves = score.parts.reduce(0) { $0 + $1.staves.count }
let measures = score.parts.first?.staves.first?.measures.count ?? 0
let elements = score.parts.reduce(0) { total, part in
    total + part.staves.reduce(0) { staffTotal, staff in
        staffTotal + staff.measures.reduce(0) { measureTotal, measure in
            measureTotal + measure.voices.reduce(0) { $0 + $1.elements.count }
        }
    }
}

print("fingerprint=\(score.stableFingerprint)")
print("division=\(score.division)")
print("parts=\(score.parts.count)")
print("staves=\(staves)")
print("measures=\(measures)")
print("elements=\(elements)")
