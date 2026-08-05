package com.example.mediahelper.imaging

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import kotlin.math.max

enum class StitchAxis(val label: String) { VERTICAL("Vertical"), HORIZONTAL("Horizontal") }

/** Bitmap ports of iOS ImageSquarifier + ImageStitcher. */
object ImageOps {

    /** Pad a non-square bitmap to a square canvas, filling with the top-left
     *  pixel colour, original centered. Short side = max(w, h) so nothing is lost. */
    fun squarify(src: Bitmap): Bitmap {
        val w = src.width
        val h = src.height
        if (w <= 0 || h <= 0 || w == h) return src
        val side = max(w, h)
        val out = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
        Canvas(out).apply {
            drawColor(src.getPixel(0, 0))
            drawBitmap(src, ((side - w) / 2).toFloat(), ((side - h) / 2).toFloat(), null)
        }
        return out
    }

    /** Combine images into one, matching widths (vertical) or heights
     *  (horizontal) to the smallest input, with an optional 1px divider. */
    fun stitch(images: List<Bitmap>, axis: StitchAxis, divider: Boolean): Bitmap? {
        if (images.isEmpty()) return null
        if (images.size == 1) return images[0]
        return if (axis == StitchAxis.VERTICAL) stitchVertical(images, divider)
        else stitchHorizontal(images, divider)
    }

    private val blackFill = Paint().apply { color = Color.BLACK }

    private fun stitchVertical(images: List<Bitmap>, divider: Boolean): Bitmap? {
        val targetWidth = images.minOf { it.width }
        if (targetWidth <= 0) return null
        val scaled = images.map { img ->
            val scale = targetWidth.toFloat() / img.width
            Bitmap.createScaledBitmap(img, targetWidth, (img.height * scale).toInt().coerceAtLeast(1), true)
        }
        val sep = if (divider) images.size - 1 else 0
        val totalHeight = scaled.sumOf { it.height } + sep
        val out = Bitmap.createBitmap(targetWidth, totalHeight, Bitmap.Config.ARGB_8888)
        val c = Canvas(out)
        var y = 0
        scaled.forEachIndexed { i, bmp ->
            c.drawBitmap(bmp, 0f, y.toFloat(), null)
            y += bmp.height
            if (divider && i < scaled.size - 1) {
                c.drawRect(0f, y.toFloat(), targetWidth.toFloat(), (y + 1).toFloat(), blackFill)
                y += 1
            }
        }
        return out
    }

    private fun stitchHorizontal(images: List<Bitmap>, divider: Boolean): Bitmap? {
        val targetHeight = images.minOf { it.height }
        if (targetHeight <= 0) return null
        val scaled = images.map { img ->
            val scale = targetHeight.toFloat() / img.height
            Bitmap.createScaledBitmap(img, (img.width * scale).toInt().coerceAtLeast(1), targetHeight, true)
        }
        val sep = if (divider) images.size - 1 else 0
        val totalWidth = scaled.sumOf { it.width } + sep
        val out = Bitmap.createBitmap(totalWidth, targetHeight, Bitmap.Config.ARGB_8888)
        val c = Canvas(out)
        var x = 0
        scaled.forEachIndexed { i, bmp ->
            c.drawBitmap(bmp, x.toFloat(), 0f, null)
            x += bmp.width
            if (divider && i < scaled.size - 1) {
                c.drawRect(x.toFloat(), 0f, (x + 1).toFloat(), targetHeight.toFloat(), blackFill)
                x += 1
            }
        }
        return out
    }
}
