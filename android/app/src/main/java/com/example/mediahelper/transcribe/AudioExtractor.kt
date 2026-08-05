package com.example.mediahelper.transcribe

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.ByteBuffer
import java.util.UUID

/** Extracts the audio track of a video into an .m4a (no re-encode) so cloud
 *  uploads stay small and fit OpenAI's 25 MB cap. Mirrors iOS AudioExtractor. */
object AudioExtractor {

    suspend fun extractToM4a(context: Context, source: Uri): File = withContext(Dispatchers.IO) {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(context, source, null)
        } catch (e: Exception) {
            extractor.release()
            throw TranscriptionError.AudioExtractionFailed(e.message ?: "couldn't read video")
        }

        var audioTrack = -1
        var format: MediaFormat? = null
        for (i in 0 until extractor.trackCount) {
            val f = extractor.getTrackFormat(i)
            if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                audioTrack = i; format = f; break
            }
        }
        if (audioTrack < 0 || format == null) {
            extractor.release()
            throw TranscriptionError.AudioExtractionFailed("no audio track in this video")
        }
        extractor.selectTrack(audioTrack)

        val out = File(context.cacheDir, "${UUID.randomUUID()}.m4a")
        val muxer = MediaMuxer(out.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        val dstTrack = muxer.addTrack(format)
        muxer.start()

        val maxInput = if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE))
            format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE) else (1 shl 20)
        val buffer = ByteBuffer.allocate(maxInput)
        val info = MediaCodec.BufferInfo()

        try {
            while (true) {
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
                info.offset = 0
                info.size = size
                info.presentationTimeUs = extractor.sampleTime
                info.flags = if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0)
                    MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                muxer.writeSampleData(dstTrack, buffer, info)
                extractor.advance()
            }
        } catch (e: Exception) {
            throw TranscriptionError.AudioExtractionFailed(e.message ?: "muxing failed")
        } finally {
            runCatching { muxer.stop() }
            runCatching { muxer.release() }
            extractor.release()
        }
        out
    }
}
