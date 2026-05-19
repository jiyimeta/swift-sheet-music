package com.example.sheetmusic

import com.example.sheetmusic.draw.DrawProgram

sealed interface ScoreState {
    data object Loading : ScoreState
    data object MissingFixture : ScoreState
    data class ParseError(val message: String) : ScoreState
    data class Ready(
        val program: DrawProgram,
        val currentPage: Int,
        val pageCount: Int,
    ) : ScoreState
}
