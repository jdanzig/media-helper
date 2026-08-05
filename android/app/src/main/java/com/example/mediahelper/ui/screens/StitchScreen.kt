package com.example.mediahelper.ui.screens

import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
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
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.example.mediahelper.download.GallerySaver
import com.example.mediahelper.imaging.BitmapIo
import com.example.mediahelper.imaging.ImageOps
import com.example.mediahelper.imaging.StitchAxis
import kotlinx.coroutines.launch

/** Stitch: pick up to 20 images, combine vertically or horizontally with an
 *  optional divider, save. Mirrors iOS StitchView (drag-reorder omitted;
 *  order follows selection). */
@Composable
fun StitchScreen(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val images: SnapshotStateList<Bitmap> = remember { mutableStateListOf() }
    var axis by remember { mutableStateOf(StitchAxis.VERTICAL) }
    var divider by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<Bitmap?>(null) }
    var status by remember { mutableStateOf("Pick images to stitch.") }

    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(20)
    ) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        scope.launch {
            status = "Loading ${uris.size} image(s)…"
            images.clear()
            runCatching { uris.forEach { images.add(BitmapIo.load(context, it)) } }
                .onSuccess { status = "${images.size} image(s) loaded." }
                .onFailure { status = it.message ?: "Couldn't load images." }
        }
    }

    Column(
        modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Stitch", style = MaterialTheme.typography.headlineSmall)

        OutlinedButton(
            onClick = {
                picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            },
            modifier = Modifier.fillMaxWidth(),
        ) { Text("Pick images") }

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip(axis == StitchAxis.VERTICAL, { axis = StitchAxis.VERTICAL }, { Text("Vertical") })
            FilterChip(axis == StitchAxis.HORIZONTAL, { axis = StitchAxis.HORIZONTAL }, { Text("Horizontal") })
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Switch(checked = divider, onCheckedChange = { divider = it })
            Text("Divider line")
        }

        Button(
            onClick = { result = ImageOps.stitch(images.toList(), axis, divider); status = if (result != null) "Ready to save." else "Need at least one image." },
            enabled = images.isNotEmpty(),
            modifier = Modifier.fillMaxWidth(),
        ) { Text("Stitch") }

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
