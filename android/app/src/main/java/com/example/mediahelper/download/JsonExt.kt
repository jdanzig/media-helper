package com.example.mediahelper.download

import org.json.JSONArray
import org.json.JSONObject

/** Null-safe accessors — org.json's optString coerces JSON null to "null",
 *  which these avoid. */
fun JSONObject.stringOrNull(key: String): String? =
    if (has(key) && !isNull(key)) optString(key).takeIf { it.isNotEmpty() } else null

fun JSONObject.objOrNull(key: String): JSONObject? = optJSONObject(key)
fun JSONObject.arrOrNull(key: String): JSONArray? = optJSONArray(key)

fun JSONArray.objects(): List<JSONObject> =
    (0 until length()).mapNotNull { optJSONObject(it) }
