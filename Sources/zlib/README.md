# Vendored zlib (WebAssembly only)

zlib 1.3.1, by Jean-loup Gailly and Mark Adler, under the zlib License
(`LICENSE` in this directory). Upstream:
<https://zlib.net/fossils/zlib-1.3.1.tar.gz>,
SHA-256 `9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23`.

## Why it is here

`SheetMusicZip` reaches zlib three different ways. Apple platforms use
`Compression` and never touch it. Linux and Android link the system
`libz` — the manifest's `.linkedLibrary("z")` — and resolve `import zlib`
against the modulemap in their sysroot. The WebAssembly SDK ships
neither, and `.mscx` parsing is unreachable without it: `SheetMusicMSCX`
and `SheetMusicMusicXML` both depend on `SheetMusicZip` unconditionally.

This target fills that one hole. It is added to the package **only when
`SWIFT_SHEET_MUSIC_WASM=1`** (see `Package.swift`), so the Apple and
Android builds are byte-identical to what they were before it existed,
and the shipping package shape carries no vendored C.

The target is named `zlib` rather than something like `CZlib` on purpose:
the module name has to match what Linux and Android already provide, or
`DeflateZLib.swift` would need a per-platform import alias for no gain.

## What was taken

The raw-DEFLATE subset — eight translation units and their headers:

    adler32.c  crc32.c  deflate.c  inffast.c
    inflate.c  inftrees.c  trees.c  zutil.c

Left behind: the gzip file-I/O group (`gzclose.c`, `gzlib.c`,
`gzread.c`, `gzwrite.c`, `gzguts.h`), the callback inflate variant
(`infback.c`), and the one-shot wrappers (`compress.c`, `uncompr.c`).
None are reachable from this package, which drives `deflate` / `inflate`
directly at `windowBits = -15`. `NO_GZIP` is defined in the manifest so
the gzip wrapper code inside `deflate.c` and `inflate.c` compiles out
too.

`Z_SOLO` would strip more, but it also removes zlib's default allocator,
and `DeflateZLib.swift` relies on that by leaving `zalloc` / `zfree` null
on a zeroed `z_stream`.

## Updating

Re-run the staging script against a new tarball and re-check the
checksum above:

    Scripts/vendor-zlib.sh <tarball> Sources/zlib

Sources are unmodified from upstream; keep it that way, so a bump is a
copy rather than a merge.
