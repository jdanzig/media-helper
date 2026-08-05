package com.example.mediahelper.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.example.mediahelper.download.SocialPlatform
import com.example.mediahelper.ui.viewmodel.DownloadViewModel

@Composable
fun DownloadScreen(modifier: Modifier = Modifier, vm: DownloadViewModel = viewModel()) {
    Column(
        modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Download", style = MaterialTheme.typography.headlineSmall)

        OutlinedTextField(
            value = vm.urlText,
            onValueChange = vm::onUrlChange,
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            placeholder = { Text("Paste a video/post URL") },
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None),
            enabled = !vm.isBusy,
        )

        if (vm.detectedPlatform != SocialPlatform.UNKNOWN) {
            Text(
                "Detected ${vm.detectedPlatform.displayName}",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.primary,
            )
        }

        Button(
            onClick = vm::start,
            enabled = !vm.isBusy && vm.detectedPlatform != SocialPlatform.UNKNOWN,
            modifier = Modifier.fillMaxWidth(),
        ) { Text(if (vm.isBusy) "Working…" else "Download") }

        if (vm.isBusy && vm.progress > 0) {
            LinearProgressIndicator(progress = { vm.progress.toFloat() }, modifier = Modifier.fillMaxWidth())
        }

        Text(vm.status, style = MaterialTheme.typography.bodyMedium)

        OutlinedButton(onClick = vm::clear, enabled = !vm.isBusy) { Text("Clear") }
    }
}
