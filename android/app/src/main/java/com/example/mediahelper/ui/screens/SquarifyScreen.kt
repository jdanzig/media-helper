package com.example.mediahelper.ui.screens

import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.example.mediahelper.download.GallerySaver
import com.example.mediahelper.imaging.BitmapIo
import com.example.mediahelper.imaging.ImageOps
import kotlinx.coroutines.launch

/** Squarify: pick an image, pad it to a square with the top-left pixel colour,
 *  save to the gallery. Mirrors iOS SquarifyView (interactive pan/zoom omitted). */
@Composable
fun SquarifyScreen(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var result by remember { mutableStateOf<Bitmap?>(null) }
    var status by remember { mutableStateOf("Pick an image to squarify.") }

    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            status = "Working…"
            runCatching { ImageOps.squarify(BitmapIo.load(context, uri)) }
                .onSuccess { result = it; status = "Ready to save." }
                .onFailure { status = it.message ?: "Couldn't load image." }
        }
    }

    Column(
        modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Squarify", style = MaterialTheme.typography.headlineSmall)

        OutlinedButton(
            onClick = {
                picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            },
            modifier = Modifier.fillMaxWidth(),
        ) { Text("Pick image") }

        result?.let { bmp ->
            Image(bmp.asImageBitmap(), contentDescription = null, modifier = Modifier.fillMaxWidth())
            Button(
                onClick = {
                    scope.launch {
                        status = "Saving…"
                        runCatching { GallerySaver.saveBitmap(context, bmp) }
                            .onSuccess { status = "Saved to your gallery." }
                            .onFailure { status = it.message ?: "Save failed." }
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Save to gallery") }
        }

        Text(status, style = MaterialTheme.typography.bodyMedium)
    }
}
