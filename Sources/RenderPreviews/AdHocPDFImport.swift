#if os(macOS)
    import Foundation
    import SheetMusicCore
    import SheetMusicLayoutApple
    import SheetMusicOMRModel
    import SheetMusicPDF

    /// Ad-hoc single-PDF import path used to point `PDFImporter.parse(pdfURL:)`
    /// at a chosen file and see exactly what it read. Before this existed
    /// there was no way to exercise the PDF importer on a real file outside
    /// a throwaway test — `swift run render-previews` otherwise only knows
    /// `.mscz` / `.mscx` (see `AdHocRender`).
    ///
    /// Driven entirely by environment variables, mirroring `AdHocRender`:
    ///
    ///   SM_PDF      — path to a PDF (required to activate, tilde-expanded)
    ///   SM_PDF_OUT  — optional output PNG path; when set, the parsed score
    ///             is also rendered via the shared `renderScoreToPNG` helper
    ///   SM_PDF_OMR  — optional; `1` constructs `CoreMLTileClassifier()` and
    ///             assigns it to `options.omrTileClassifier`, so the tool can
    ///             also exercise the scanned-page (raster) path. Unset — the
    ///             default — leaves it `nil`, which is specified to mean the
    ///             importer behaves exactly as it always has.
    ///
    /// Usage:
    ///   SM_PDF=~/Documents/.../foo.pdf swift run render-previews
    @available(macOS 15.0, *)
    @MainActor
    enum AdHocPDFImport {
        static var isRequested: Bool {
            ProcessInfo.processInfo.environment["SM_PDF"] != nil
        }

        static func run() async throws {
            let env = ProcessInfo.processInfo.environment
            guard let pdfPath = env["SM_PDF"] else { return }
            let url = URL(
                fileURLWithPath: (pdfPath as NSString)
                    .expandingTildeInPath,
            )

            var options = PDFImportOptions()
            options.diagnostics = { diagnostic in
                let severity = switch diagnostic.severity {
                case .info: "info"
                case .warning: "warning"
                }
                var line = "[\(severity)] \(diagnostic.location): \(diagnostic.message)"
                if let context = diagnostic.context {
                    line += " (\(context))"
                }
                print(line)
            }
            if env["SM_PDF_OMR"] == "1" {
                options.omrTileClassifier = try CoreMLTileClassifier()
            }

            print("parsing \(url.path)")
            let score = try PDFImporter.parse(pdfURL: url, options: options)
            printSummary(of: score)

            if let outPath = env["SM_PDF_OUT"] {
                _ = SheetMusicLayoutApple.install
                let outURL = URL(fileURLWithPath: outPath)
                try FileManager.default.createDirectory(
                    at: outURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                )
                try renderScoreToPNG(score, to: outURL, scale: 2)
                print("wrote \(outURL.path)")
            }
        }

        /// Prints part/staff/measure counts and a note/rest tally. Only
        /// reports fields `Score` actually carries — no invented summary
        /// shape.
        private static func printSummary(of score: Score) {
            // `Score.systemMeasures` is documented to track the per-staff
            // `measures.count` for any part/staff with real content, so it's
            // the score-level measure count; fall back to the first staff
            // directly in case that invariant hasn't been populated.
            let measureCount = !score.systemMeasures.isEmpty
                ? score.systemMeasures.count
                : (score.parts.first?.staves.first?.measures.count ?? 0)

            var noteCount = 0
            var restCount = 0
            for part in score.parts {
                for staff in part.staves {
                    for measure in staff.measures {
                        for voice in measure.voices {
                            for element in voice.elements {
                                guard case let .chord(chord) = element
                                else { continue }
                                if chord.notes.isEmpty {
                                    restCount += 1
                                } else {
                                    noteCount += chord.notes.count
                                }
                            }
                        }
                    }
                }
            }

            print("--- Score summary ---")
            print("parts: \(score.parts.count)")
            for (index, part) in score.parts.enumerated() {
                let name = part.instrument.longName
                    ?? part.instrument.shortName
                    ?? part.instrument.trackName
                    ?? part.instrument.id
                print("  part \(index) (\(name)): \(part.staves.count) staves")
            }
            print("measures: \(measureCount)")
            print("notes: \(noteCount)")
            print("rests: \(restCount)")

            if let titleFrame = score.titleFrame {
                let relevant = titleFrame.texts.filter { $0.style != .other }
                if relevant.isEmpty {
                    print("titleFrame: present, no title/subtitle/composer/lyricist text")
                } else {
                    for text in relevant {
                        print("\(text.style.rawValue): \(text.text)")
                    }
                }
            } else {
                print("titleFrame: none")
            }
        }
    }
#endif
