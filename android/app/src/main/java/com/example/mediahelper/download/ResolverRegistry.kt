package com.example.mediahelper.download

import com.example.mediahelper.download.resolvers.FacebookResolver
import com.example.mediahelper.download.resolvers.InstagramResolver
import com.example.mediahelper.download.resolvers.StreamableResolver
import com.example.mediahelper.download.resolvers.ThreadsResolver
import com.example.mediahelper.download.resolvers.TikTokResolver
import com.example.mediahelper.download.resolvers.TwitterResolver
import com.example.mediahelper.download.resolvers.VimeoResolver
import com.example.mediahelper.download.resolvers.YouTubeResolver

/** Maps a detected platform to its resolver. Mirrors the switch in the iOS
 *  DownloadViewModel. */
object ResolverRegistry {
    fun resolverFor(platform: SocialPlatform): MediaResolver? = when (platform) {
        SocialPlatform.YOUTUBE -> YouTubeResolver()
        SocialPlatform.TWITTER -> TwitterResolver()
        SocialPlatform.TIKTOK -> TikTokResolver()
        SocialPlatform.INSTAGRAM -> InstagramResolver()
        SocialPlatform.FACEBOOK -> FacebookResolver()
        SocialPlatform.THREADS -> ThreadsResolver()
        SocialPlatform.STREAMABLE -> StreamableResolver()
        SocialPlatform.VIMEO -> VimeoResolver()
        SocialPlatform.UNKNOWN -> null
    }
}
