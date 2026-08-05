package com.example.mediahelper.ui.screens

import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.example.mediahelper.transcribe.TranscriptionBackend
import com.example.mediahelper.ui.viewmodel.TranscribeViewModel

@Composable
fun TranscribeScreen(modifier: Modifier = Modifier, vm: TranscribeViewModel = viewModel()) {
    val context = LocalContext.current

    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia()
    ) { uri -> if (uri != null) vm.pickVideo(uri) }

    Column(
        modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Transcribe", style = MaterialTheme.typography.headlineSmall)

        OutlinedButton(
            onClick = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly)) },
            enabled = !vm.isBusy,
            modifier = Modifier.fillMaxWidth(),
        ) { Text(if (vm.video == null) "Pick video" else "Change video") }

        Text("Backend", style = MaterialTheme.typography.titleSmall)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            vm.backends.forEach { b ->
                FilterChip(vm.backend == b, { vm.backend = b }, { Text(b.displayName) })
            }
        }

        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Switch(checked = vm.makeSubtitles, onCheckedChange = { vm.makeSubtitles = it })
            Text("Also make .srt subtitles")
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Switch(
                checked = vm.translate,
                onCheckedChange = { vm.translate = it },
                enabled = vm.backend.supportsTranslation,
            )
            Text("Translate to English")
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Switch(
                checked = vm.speakerLabels,
                onCheckedChange = { vm.speakerLabels = it },
                enabled = vm.backend.supportsDiarization,
            )
            Text("Speaker labels (AssemblyAI)")
        }

        Button(
            onClick = vm::start,
            enabled = !vm.isBusy && vm.video != null,
            modifier = Modifier.fillMaxWidth(),
        ) { Text(if (vm.isBusy) "Working…" else "Start") }

        if (vm.isBusy && vm.progress > 0) {
            LinearProgressIndicator(progress = { vm.progress.toFloat() }, modifier = Modifier.fillMaxWidth())
        }

        Text(vm.status, style = MaterialTheme.typography.bodyMedium)

        vm.transcript?.let { text ->
            Button(
                onClick = {
                    val send = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, vm.srt ?: text)
                    }
                    context.startActivity(Intent.createChooser(send, "Share transcript"))
                },
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Share ${if (vm.srt != null) ".srt" else "transcript"}") }

            Text(text, style = MaterialTheme.typography.bodySmall)
        }
    }
}
