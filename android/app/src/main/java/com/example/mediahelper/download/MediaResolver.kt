package com.example.mediahelper.download

/** A resolver turns a social page URL into a direct media URL. Mirrors iOS
 *  MediaResolver; `resolveAll` defaults to wrapping `resolve`. */
interface MediaResolver {
    val platform: SocialPlatform
    suspend fun resolve(url: String): ResolverResult
    suspend fun resolveAll(url: String): List<ResolverResult> = listOf(resolve(url))
}
