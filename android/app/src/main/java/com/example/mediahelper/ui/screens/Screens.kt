package com.example.mediahelper.ui.screens

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier

// Remaining placeholder — Transcribe lands in a later milestone.
@Composable
private fun Placeholder(name: String, modifier: Modifier) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text("$name — coming soon")
    }
}

@Composable
fun TranscribeScreen(modifier: Modifier = Modifier) = Placeholder("Transcribe", modifier)
