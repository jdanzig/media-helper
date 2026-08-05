package com.example.mediahelper.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ClosedCaption
import androidx.compose.material.icons.filled.CropSquare
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.ViewColumn
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import com.example.mediahelper.ui.screens.DownloadScreen
import com.example.mediahelper.ui.screens.SettingsScreen
import com.example.mediahelper.ui.screens.SquarifyScreen
import com.example.mediahelper.ui.screens.StitchScreen
import com.example.mediahelper.ui.screens.TranscribeScreen

/// Mirrors the iOS RootTabView: Download / Transcribe / Stitch / Squarify /
/// Settings. State-held selection (no nav dependency yet — scaffold only).
private enum class Tab(val title: String, val icon: ImageVector) {
    Download("Download", Icons.Filled.Download),
    Transcribe("Transcribe", Icons.Filled.ClosedCaption),
    Stitch("Stitch", Icons.Filled.ViewColumn),
    Squarify("Squarify", Icons.Filled.CropSquare),
    Settings("Settings", Icons.Filled.Settings),
}

@Composable
fun RootTabView() {
    var selected by remember { mutableStateOf(Tab.Download) }
    Scaffold(
        bottomBar = {
            NavigationBar {
                Tab.entries.forEach { tab ->
                    NavigationBarItem(
                        selected = selected == tab,
                        onClick = { selected = tab },
                        icon = { Icon(tab.icon, contentDescription = tab.title) },
                        label = { Text(tab.title) },
                    )
                }
            }
        },
    ) { padding ->
        val mod = Modifier.padding(padding)
        when (selected) {
            Tab.Download -> DownloadScreen(mod)
            Tab.Transcribe -> TranscribeScreen(mod)
            Tab.Stitch -> StitchScreen(mod)
            Tab.Squarify -> SquarifyScreen(mod)
            Tab.Settings -> SettingsScreen(mod)
        }
    }
}
