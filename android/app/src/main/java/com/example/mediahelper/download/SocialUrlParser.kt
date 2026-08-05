package com.example.mediahelper.download

import android.net.Uri

/** Turns a pasted string into a URL and classifies its platform, stripping
 *  tracking/share params. Mirrors iOS SocialURLParser. Pure value-in/out. */
object SocialUrlParser {

    fun uriFrom(raw: String): Uri? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        val withScheme = if (Uri.parse(trimmed).scheme != null) trimmed else "https://$trimmed"
        val u = runCatching { Uri.parse(withScheme) }.getOrNull() ?: return null
        if (u.host == null) return null
        return stripTrackingParams(u)
    }

    fun stripTrackingParams(url: Uri): Uri {
        if (url.query == null) return url
        return when (detectPlatform(url)) {
            SocialPlatform.YOUTUBE -> {
                if (url.host?.lowercase()?.endsWith("youtu.be") == true) removeQuery(url)
                else url.getQueryParameter("v")?.let { v ->
                    url.buildUpon().clearQuery().appendQueryParameter("v", v).build()
                } ?: removeQuery(url)
            }
            SocialPlatform.FACEBOOK -> {
                val pathIsWatch = url.path?.trim('/')?.lowercase() == "watch"
                val v = url.getQueryParameter("v")
                if (pathIsWatch && v != null) {
                    url.buildUpon().clearQuery().appendQueryParameter("v", v).build()
                } else removeQuery(url)
            }
            else -> removeQuery(url) // twitter, tiktok, instagram, threads, unknown
        }
    }

    private fun removeQuery(url: Uri): Uri = url.buildUpon().clearQuery().fragment(url.fragment).build()

    fun detectPlatform(url: Uri): SocialPlatform {
        var host = url.host?.lowercase() ?: return SocialPlatform.UNKNOWN
        for (prefix in listOf("www.", "m.", "mobile.", "vm.", "vt.")) {
            if (host.startsWith(prefix)) host = host.substring(prefix.length)
        }
        return when (host) {
            "youtube.com", "youtu.be", "youtube-nocookie.com" -> SocialPlatform.YOUTUBE
            "twitter.com", "x.com", "t.co" -> SocialPlatform.TWITTER
            "tiktok.com" -> SocialPlatform.TIKTOK
            "instagram.com" -> SocialPlatform.INSTAGRAM
            "facebook.com", "fb.com", "fb.watch" -> SocialPlatform.FACEBOOK
            "threads.net", "threads.com" -> SocialPlatform.THREADS
            "streamable.com" -> SocialPlatform.STREAMABLE
            "vimeo.com", "player.vimeo.com" -> SocialPlatform.VIMEO
            else -> SocialPlatform.UNKNOWN
        }
    }
}
