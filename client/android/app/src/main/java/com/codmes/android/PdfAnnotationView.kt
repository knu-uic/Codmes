package com.codmes.android

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.util.TypedValue
import android.view.MotionEvent
import android.view.View
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import kotlin.math.max
import kotlin.math.min

class PdfAnnotationView(context: Context) : View(context) {
    enum class Tool { PAN, PEN, RECTANGLE, TEXT }

    var tool = Tool.PAN
    var onTextRequested: ((Double, Double) -> Unit)? = null
    private var bitmap: Bitmap? = null
    private var document = JSONObject()
    private var pageIndex = 0
    private var activePoints: JSONArray? = null
    private var startPoint: Pair<Double, Double>? = null
    private val pageRect = RectF()
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)

    fun setPage(image: Bitmap, annotations: JSONObject, index: Int) {
        bitmap = image
        document = annotations
        pageIndex = index
        invalidate()
    }

    fun annotationDocument(): JSONObject = document

    fun addText(x: Double, y: Double, value: String) {
        if (value.isBlank()) return
        objects().put(JSONObject()
            .put("id", "text-${UUID.randomUUID()}")
            .put("type", "text")
            .put("pageIndex", pageIndex)
            .put("text", value)
            .put("bbox", JSONObject()
                .put("x", x).put("y", y)
                .put("width", min(0.45, max(0.12, value.length * 0.018)))
                .put("height", 0.08))
            .put("metadata", JSONObject().put("color", "#111111").put("fontSize", "16")))
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val image = bitmap ?: return
        val scale = min(width.toFloat() / image.width, height.toFloat() / image.height)
        val drawWidth = image.width * scale
        val drawHeight = image.height * scale
        pageRect.set((width - drawWidth) / 2, (height - drawHeight) / 2, (width + drawWidth) / 2, (height + drawHeight) / 2)
        canvas.drawColor(Color.rgb(232, 232, 232))
        canvas.drawBitmap(image, null, pageRect, paint)
        canvas.save()
        canvas.clipRect(pageRect)
        drawStrokes(canvas)
        drawObjects(canvas)
        canvas.restore()
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val point = normalized(event.x, event.y) ?: return false
        when (tool) {
            Tool.PAN -> return false
            Tool.PEN -> when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    activePoints = JSONArray().put(point(point.first, point.second, event.pressure))
                    parent.requestDisallowInterceptTouchEvent(true)
                }
                MotionEvent.ACTION_MOVE -> activePoints?.put(point(point.first, point.second, event.pressure))
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    activePoints?.takeIf { it.length() > 1 }?.let {
                        strokes().put(JSONObject()
                            .put("id", "stroke-${UUID.randomUUID()}")
                            .put("tool", "pen").put("color", "#1769aa").put("width", 2.5)
                            .put("opacity", 1.0).put("points", it))
                    }
                    activePoints = null
                    parent.requestDisallowInterceptTouchEvent(false)
                }
                else -> Unit
            }
            Tool.RECTANGLE -> when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> startPoint = point
                MotionEvent.ACTION_UP -> {
                    startPoint?.let { start ->
                        val x = min(start.first, point.first)
                        val y = min(start.second, point.second)
                        objects().put(JSONObject()
                            .put("id", "rectangle-${UUID.randomUUID()}")
                            .put("type", "rectangle").put("pageIndex", pageIndex)
                            .put("bbox", JSONObject().put("x", x).put("y", y)
                                .put("width", max(0.005, kotlin.math.abs(point.first - start.first)))
                                .put("height", max(0.005, kotlin.math.abs(point.second - start.second))))
                            .put("metadata", JSONObject().put("color", "#d32f2f").put("lineWidth", "2")))
                    }
                    startPoint = null
                }
                else -> Unit
            }
            Tool.TEXT -> if (event.actionMasked == MotionEvent.ACTION_UP) onTextRequested?.invoke(point.first, point.second)
        }
        invalidate()
        return true
    }

    private fun drawStrokes(canvas: Canvas) {
        val values = page().optJSONArray("inkStrokes") ?: return
        for (index in 0 until values.length()) {
            val stroke = values.getJSONObject(index)
            val points = stroke.optJSONArray("points") ?: continue
            paint.style = Paint.Style.STROKE
            paint.strokeCap = Paint.Cap.ROUND
            paint.strokeJoin = Paint.Join.ROUND
            paint.color = parseColor(stroke.optString("color", "#1769aa"))
            paint.alpha = (stroke.optDouble("opacity", 1.0) * 255).toInt().coerceIn(0, 255)
            paint.strokeWidth = stroke.optDouble("width", 2.5).toFloat() * resources.displayMetrics.density
            for (pointIndex in 1 until points.length()) {
                val previous = points.getJSONObject(pointIndex - 1)
                val current = points.getJSONObject(pointIndex)
                canvas.drawLine(px(previous.optDouble("x")), py(previous.optDouble("y")), px(current.optDouble("x")), py(current.optDouble("y")), paint)
            }
        }
        activePoints?.let { points ->
            paint.style = Paint.Style.STROKE
            paint.color = Color.rgb(23, 105, 170)
            paint.alpha = 255
            paint.strokeWidth = 2.5f * resources.displayMetrics.density
            for (index in 1 until points.length()) {
                val previous = points.getJSONObject(index - 1)
                val current = points.getJSONObject(index)
                canvas.drawLine(px(previous.optDouble("x")), py(previous.optDouble("y")), px(current.optDouble("x")), py(current.optDouble("y")), paint)
            }
        }
    }

    private fun drawObjects(canvas: Canvas) {
        val values = page().optJSONArray("objects") ?: return
        for (index in 0 until values.length()) {
            val item = values.getJSONObject(index)
            val box = item.optJSONObject("bbox") ?: continue
            val rect = RectF(px(box.optDouble("x")), py(box.optDouble("y")),
                px(box.optDouble("x") + box.optDouble("width")), py(box.optDouble("y") + box.optDouble("height")))
            paint.alpha = 255
            paint.color = parseColor(item.optJSONObject("metadata")?.optString("color", "#d32f2f") ?: "#d32f2f")
            if (item.optString("type") == "text") {
                paint.style = Paint.Style.FILL
                paint.textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 16f, resources.displayMetrics)
                canvas.drawText(item.optString("text"), rect.left, rect.top + paint.textSize, paint)
            } else {
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = 2f * resources.displayMetrics.density
                canvas.drawRect(rect, paint)
            }
        }
    }

    private fun normalized(x: Float, y: Float): Pair<Double, Double>? {
        if (!pageRect.contains(x, y)) return null
        return Pair(((x - pageRect.left) / pageRect.width()).toDouble(), ((y - pageRect.top) / pageRect.height()).toDouble())
    }
    private fun point(x: Double, y: Double, pressure: Float) =
        JSONObject().put("x", x).put("y", y).put("pressure", pressure.toDouble())
    private fun page(): JSONObject {
        val pages = document.optJSONArray("pages") ?: JSONArray().also { document.put("pages", it) }
        for (index in 0 until pages.length()) if (pages.getJSONObject(index).optInt("pageIndex") == pageIndex) return pages.getJSONObject(index)
        return JSONObject().put("pageIndex", pageIndex).put("inkStrokes", JSONArray()).put("objects", JSONArray()).also { pages.put(it) }
    }
    private fun strokes() = page().optJSONArray("inkStrokes") ?: JSONArray().also { page().put("inkStrokes", it) }
    private fun objects() = page().optJSONArray("objects") ?: JSONArray().also { page().put("objects", it) }
    private fun px(value: Double) = pageRect.left + (value * pageRect.width()).toFloat()
    private fun py(value: Double) = pageRect.top + (value * pageRect.height()).toFloat()
    private fun parseColor(value: String) = try { Color.parseColor(value) } catch (_: Exception) { Color.BLACK }
}
