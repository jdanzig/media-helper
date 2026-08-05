package com.example.mediahelper.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import com.example.mediahelper.store.SecureStore

/** Settings: API keys for the cloud transcription backends and session
 *  cookies for gated Instagram/TikTok posts. Mirrors iOS SettingsView. */
@Composable
fun SettingsScreen(modifier: Modifier = Modifier) {
    Column(
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
        Text(
            "Keys and cookies are stored on this device only.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        CredentialSection(
            title = "OpenAI Whisper",
            tagline = "Powers the OpenAI Whisper transcription backend.",
            item = SecureStore.Item.OpenAIApiKey,
            hint = "API key",
        )
        CredentialSection(
            title = "AssemblyAI",
            tagline = "Required for the AssemblyAI backend (includes speaker labels).",
            item = SecureStore.Item.AssemblyAIApiKey,
            hint = "API key",
        )
        CredentialSection(
            title = "Instagram",
            tagline = "Some posts are restricted to logged-in users. Paste your sessionid cookie to unlock them (Instagram.com → DevTools → Application → Cookies).",
            item = SecureStore.Item.InstagramSessionCookie,
            hint = "sessionid value",
        )
        CredentialSection(
            title = "TikTok",
            tagline = "Age-restricted posts need a login. Paste your sessionid cookie to unlock them (TikTok.com → DevTools → Application → Cookies).",
            item = SecureStore.Item.TikTokSessionCookie,
            hint = "sessionid value",
        )
    }
}

@Composable
private fun CredentialSection(
    title: String,
    tagline: String,
    item: SecureStore.Item,
    hint: String,
) {
    var saved by remember { mutableStateOf(SecureStore.has(item)) }
    var input by remember { mutableStateOf("") }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium)
        Text(
            tagline,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        if (saved) {
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                Text("Saved", style = MaterialTheme.typography.bodyMedium)
                TextButton(onClick = { SecureStore.delete(item); saved = false }) { Text("Remove") }
            }
        }

        OutlinedTextField(
            value = input,
            onValueChange = { input = it },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
            placeholder = { Text(if (saved) "Replace (optional)" else hint) },
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None),
        )
        Button(
            onClick = {
                val trimmed = input.trim()
                if (trimmed.isNotEmpty()) {
                    SecureStore.save(trimmed, item)
                    saved = true
                    input = ""
                }
            },
            enabled = input.trim().isNotEmpty(),
        ) { Text(if (saved) "Replace" else "Save") }
    }
}
