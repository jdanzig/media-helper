package com.example.mediahelper.ui.screens

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier

// Placeholders mirroring the iOS tabs. Real content lands feature by feature;
// split into one file per screen (as on iOS) once each grows past a stub.
@Composable
private fun Placeholder(name: String, modifier: Modifier) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text("$name — coming soon")
    }
}

@Composable
fun TranscribeScreen(modifier: Modifier = Modifier) = Placeholder("Transcribe", modifier)

@Composable
fun StitchScreen(modifier: Modifier = Modifier) = Placeholder("Stitch", modifier)

@Composable
fun SquarifyScreen(modifier: Modifier = Modifier) = Placeholder("Squarify", modifier)
