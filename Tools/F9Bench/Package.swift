// swift-tools-version: 6.2
// F9's before / after benchmark (folino 2026-11-19): the per-element timing questions on a real score, against the
// swift-sheet-music checkout SSM_PATH names (default: this repo). Build it twice — SSM_PATH at the base commit's
// checkout and at the branch's — and run the two binaries alternately. Not part of the package; never merged.
import PackageDescription

let ssmPath = Context.environment["SSM_PATH"] ?? "../.."

let package = Package(
    name: "F9Bench",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: ssmPath)],
    targets: [
        .executableTarget(
            name: "F9Bench",
            dependencies: [
                .product(name: "SheetMusicCore", package: "swift-sheet-music"),
                .product(name: "SheetMusicLoader", package: "swift-sheet-music"),
            ],
        ),
    ],
)
