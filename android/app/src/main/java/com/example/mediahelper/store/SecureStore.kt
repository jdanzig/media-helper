package com.example.mediahelper.store

import android.content.Context

/** Small key/value store for API keys and session cookies. Mirrors iOS
 *  KeychainStore. Initialised once from the Application context.
 *
 *  ponytail: private-mode SharedPreferences, not EncryptedSharedPreferences.
 *  Fine for a personal app storing your own credentials on your own device;
 *  swap in androidx.security.crypto if the threat model ever needs at-rest
 *  encryption. */
object SecureStore {
    enum class Item(val key: String) {
        OpenAIApiKey("openai.apiKey"),
        AssemblyAIApiKey("assemblyai.apiKey"),
        InstagramSessionCookie("instagram.sessionCookie"),
        TikTokSessionCookie("tiktok.sessionCookie"),
    }

    private const val PREFS = "com.example.mediahelper.keys"
    private lateinit var appContext: Context

    fun init(context: Context) { appContext = context.applicationContext }

    private fun prefs() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun save(value: String, item: Item) = prefs().edit().putString(item.key, value).apply()
    fun load(item: Item): String? = prefs().getString(item.key, null)?.takeIf { it.isNotEmpty() }
    fun delete(item: Item) = prefs().edit().remove(item.key).apply()
    fun has(item: Item): Boolean = load(item) != null
}
