package io.github.jiyimeta.sheetmusic.audio.model

/** Model for the generated ScoreArticulationKindCodec. */
sealed class ScoreArticulationKind {
    object Staccato : ScoreArticulationKind()
    object Staccatissimo : ScoreArticulationKind()
    object Tenuto : ScoreArticulationKind()
    object Accent : ScoreArticulationKind()
    object Marcato : ScoreArticulationKind()
    object AccentStaccato : ScoreArticulationKind()
    object MarcatoStaccato : ScoreArticulationKind()
    data class Unknown(val arg0: String) : ScoreArticulationKind()
}
