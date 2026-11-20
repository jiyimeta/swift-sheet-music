#if os(macOS)
    import SheetMusicBridgeCore

    @available(macOS 15.0, *)
    extension DrawProgramParity {
        /// `commands` with staff lines, ledger lines and stems stroked at MuseScore's default widths instead of the
        /// engine's: what the score would look like if `StaffMetrics` took MuseScore's `staffLineWidth` (0.11 sp,
        /// `styledef.cpp:286`), `ledgerLineWidth` (0.16 sp, `:287`) and `stemWidth` (0.10 sp, `:266`) for its own
        /// 0.13 sp, 1.5 × that for ledger lines (`LedgerLinePass`) and 0.12 sp. A comparison for the owner
        /// (`SM_PARITY_STROKE_SET`), not a renderer: strokes are recognized by their width alone, so a cue- or grace-
        /// sized stem (scaled by its `mag`) keeps the engine's.
        static func museScoreLineWidths(_ commands: [DrawCommand], spMM: Double) -> [DrawCommand] {
            let swaps: [(engine: Double, museScore: Double)] = [
                (0.13, 0.11), (0.13 * 1.5, 0.16), (0.12, 0.10),
            ]
            return commands.map { command in
                guard case let .stroke(width) = command,
                      let swap = swaps.first(where: { abs(width - $0.engine * spMM) < 1e-9 })
                else { return command }
                return .stroke(width: swap.museScore * spMM)
            }
        }
    }
#endif
