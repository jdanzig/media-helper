package com.example.mediahelper.transcribe

import kotlin.math.floor
import kotlin.math.max

/** Renders the user-facing .txt transcript. Speaker-merged paragraphs when
 *  segments carry speakers, else timestamped lines. Mirrors iOS TranscriptFormatter. */
object TranscriptFormatter {
    fun render(result: TranscriptionResult): String {
        val hasSpeakers = result.segments.any { it.speaker != null }
        val langLine = when {
            result.isTranslation -> "Translation (English)"
            !result.language.isNullOrEmpty() -> "Language: ${result.language}"
            else -> "Transcript"
        }
        val sb = StringBuilder("# $langLine\n\n")
        if (hasSpeakers) renderWithSpeakers(result.segments, sb) else renderTimestamped(result.segments, sb)
        return sb.toString()
    }

    private fun renderWithSpeakers(segments: List<TranscriptSegment>, sb: StringBuilder) {
        var current: String? = null
        val buffer = mutableListOf<String>()
        fun flush() {
            if (buffer.isEmpty()) return
            sb.append("${current ?: "Speaker"}: ${buffer.joinToString(" ")}\n\n")
            buffer.clear()
        }
        for (seg in segments) {
            if (seg.speaker != current) { flush(); current = seg.speaker }
            buffer.add(seg.text)
        }
        flush()
    }

    private fun renderTimestamped(segments: List<TranscriptSegment>, sb: StringBuilder) {
        for (seg in segments) sb.append("[${shortTimestamp(seg.start)}] ${seg.text}\n")
    }

    private fun shortTimestamp(t: Double): String {
        val s = max(0.0, t).toInt()
        val h = s / 3600; val m = (s % 3600) / 60; val sec = s % 60
        return if (h == 0) "%02d:%02d".format(m, sec) else "%02d:%02d:%02d".format(h, m, sec)
    }
}

/** Serializes segments to SRT. Mirrors iOS SubtitleRenderer. */
object SubtitleRenderer {
    fun renderSrt(segments: List<TranscriptSegment>, maxLineLength: Int = 42, includeSpeaker: Boolean = true): String {
        val sb = StringBuilder()
        segments.forEachIndexed { i, seg ->
            val prefix = if (includeSpeaker && !seg.speaker.isNullOrEmpty()) "[${seg.speaker}] " else ""
            sb.append(i + 1).append('\n')
            sb.append(timestamp(seg.start)).append(" --> ").append(timestamp(seg.end)).append('\n')
            sb.append(wrap(prefix + seg.text, maxLineLength)).append('\n').append('\n')
        }
        return sb.toString()
    }

    private fun timestamp(t: Double): String {
        val safe = max(0.0, t)
        val h = safe.toInt() / 3600
        val m = (safe.toInt() % 3600) / 60
        val s = safe.toInt() % 60
        val ms = ((safe - floor(safe)) * 1000).toInt()
        return "%02d:%02d:%02d,%03d".format(h, m, s, ms)
    }

    private fun wrap(text: String, width: Int): String {
        val words = text.split(" ").filter { it.isNotEmpty() }
        if (words.isEmpty()) return text
        val lines = mutableListOf<String>()
        var current = ""
        for (w in words) {
            when {
                current.isEmpty() -> current = w
                current.length + 1 + w.length <= width -> current += " $w"
                else -> {
                    lines.add(current); current = w
                    if (lines.size >= 2) break
                }
            }
        }
        if (current.isNotEmpty() && lines.size < 2) lines.add(current)
        else if (current.isNotEmpty()) lines[1] = lines[1] + " " + current
        return lines.joinToString("\n")
    }
}
