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
    object TenutoStaccato : ScoreArticulationKind()
    object TenutoAccent : ScoreArticulationKind()
    object MarcatoTenuto : ScoreArticulationKind()
    object StaccatissimoStroke : ScoreArticulationKind()
    object StaccatissimoWedge : ScoreArticulationKind()
    object Stress : ScoreArticulationKind()
    object Unstress : ScoreArticulationKind()
    object SoftAccent : ScoreArticulationKind()
    object SoftAccentStaccato : ScoreArticulationKind()
    object SoftAccentTenuto : ScoreArticulationKind()
    object SoftAccentTenutoStaccato : ScoreArticulationKind()
    object MuteOpen : ScoreArticulationKind()
    object MuteClosed : ScoreArticulationKind()
    object Harmonic : ScoreArticulationKind()
    object UpBow : ScoreArticulationKind()
    object DownBow : ScoreArticulationKind()
}
