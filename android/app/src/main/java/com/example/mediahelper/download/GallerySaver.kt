package com.example.mediahelper.download

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

/** Saves media to the device gallery via MediaStore (scoped storage, API 29+).
 *  Mirrors iOS PhotoLibrarySaver. No runtime permission needed on API 29+. */
object GallerySaver {

    suspend fun saveVideo(context: Context, file: File): Uri =
        insert(context, file, isVideo = true)

    suspend fun saveImage(context: Context, file: File): Uri =
        insert(context, file, isVideo = false)

    /** Compress a bitmap to JPEG and save it (Stitch/Squarify outputs). */
    suspend fun saveBitmap(context: Context, bitmap: Bitmap): Uri = withContext(Dispatchers.IO) {
        val file = File(context.cacheDir, "${UUID.randomUUID()}.jpg")
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }
        insert(context, file, isVideo = false)
    }

    private suspend fun insert(context: Context, file: File, isVideo: Boolean): Uri =
        withContext(Dispatchers.IO) {
            val resolver = context.contentResolver
            val collection = if (isVideo)
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            else
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)

            val relativeDir = if (isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES
            val mime = if (isVideo) "video/mp4" else "image/jpeg"

            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, "$relativeDir/MediaHelper")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }

            val uri = resolver.insert(collection, values)
                ?: throw DownloadError.SaveFailed("MediaStore rejected the insert.")

            try {
                resolver.openOutputStream(uri).use { out ->
                    out ?: throw DownloadError.SaveFailed("couldn't open output stream.")
                    file.inputStream().use { it.copyTo(out) }
                }
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                uri
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw DownloadError.SaveFailed(e.message ?: "write failed")
            }
        }
}
