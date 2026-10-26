package com.example.edit_video

import android.content.Context
import android.content.ContentValues
import android.os.Build
import android.provider.MediaStore
import android.net.Uri
import androidx.media3.common.Effect
import androidx.media3.transformer.Effects
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.effect.Brightness
import androidx.media3.effect.Contrast
import androidx.media3.effect.HslAdjustment
import androidx.media3.effect.RgbMatrix
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.OverlaySettings
import androidx.media3.effect.SpeedChangeEffect
import androidx.media3.effect.TextOverlay
import android.graphics.Color
import android.text.SpannableString
import android.text.Spanned
import android.text.style.AbsoluteSizeSpan
import android.text.style.ForegroundColorSpan
import com.google.common.collect.ImmutableList
import androidx.media3.effect.Presentation
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.VideoEncoderSettings
import java.io.File
import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.MimeTypes
import androidx.media3.common.MediaItem
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.TransformationRequest
import androidx.media3.transformer.Transformer
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/**
 * Pont natif Media3 Transformer â€” exÃ©cute un export vidÃ©o rÃ©el.
 *
 * API cible : Media3 1.4.1 (minSdk 19). La configuration d'export passe par
 * `Transformer.Builder.setTransformationRequest(TransformationRequest)` (dÃ©prÃ©ciÃ©e mais
 * publiquement accessible en 1.4.1). Les paramÃ¨tres avancÃ©s (outputHeight, MIME types)
 * sont passÃ©s via le Builder interne.
 *
 * Communication : MethodChannel "com.example.edit_video/export".
 * EntrÃ©es (JSON) :
 *   - "composition" : [{ "path", "startMs", "durationMs" }, ...]
 *   - "outputPath" : String
 *   - "videoMimeType" : String (ex "video/avc1")
 *   - "audioMimeType" : String (ex "audio/mp4a")
 *   - "outputHeight" : Int (0 = auto)
 * Sorties :
 *   - "progress" : { "progress" (0..1), "state" ("preparing"|"processing"|"completed"|"failed"), "message" }
 *   - "done" : { "outputPath" }
 *   - "error" : { "code", "message" }
 */
class Media3ExportService(
    private val context: Context,
    private val channel: MethodChannel
) {

    private var transformer: Transformer? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var progressHandler: Handler? = null
    private var progressPolling = false
    private var outputPath: String = ""

    fun startExport(
        compositionJson: String,
        outputPath: String,
        videoMimeType: String? = null,
        audioMimeType: String? = null,
        outputHeight: Int = 0,
        bitrate: Int = 0,
        includeAudio: Boolean = true,
        width: Int = 0,
        height: Int = 0
    ) {
        cancelExport()
        this.outputPath = outputPath
        val parsed = try {
            parseComposition(compositionJson)
        } catch (e: Exception) {
            sendError("ERR_PARSE", "Composition JSON invalide: ${e.message}")
            return
        }

        val videoItems = parsed.first
        val audioItems = parsed.second
        val textItems = parsed.third
        if (videoItems.isEmpty() && audioItems.isEmpty()) { // les textes seuls n'ont rien a exporter
            sendError("ERR_EMPTY", "Aucun clip dans la composition")
            return
        }

        val sequences = mutableListOf<EditedMediaItemSequence>()
        if (videoItems.isNotEmpty()) {
            sequences.add(EditedMediaItemSequence(
                videoItems.map { buildItem(it, !includeAudio, outputHeight, width) }))
        }
        if (audioItems.isNotEmpty() && includeAudio) {
            sequences.add(EditedMediaItemSequence(
                audioItems.map { buildItem(it, false, 0) }))
        }
        if (sequences.isEmpty()) {
            sendError("ERR_EMPTY", "Aucune piste a exporter (audio desactive)")
            return
        }
        val compositionBuilder = Composition.Builder(sequences)
        if (textItems.isNotEmpty()) {
            val overlays = textItems.map { TimedTextOverlay(it, outputHeight) }
            compositionBuilder.setEffects(
                Effects(listOf(), listOf<Effect>(OverlayEffect(ImmutableList.copyOf(overlays))))
            )
        }
        val composition = compositionBuilder.build()

        val requestBuilder = TransformationRequest.Builder()
        videoMimeType?.let { requestBuilder.setVideoMimeType(it) }
        audioMimeType?.let { requestBuilder.setAudioMimeType(it) }
        val request = requestBuilder.build()

        val builder = Transformer.Builder(context)
            .setTransformationRequest(request)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    progressPolling = false
                    // Copie vers la galerie hors du thread principal (fichiers volumineux).
                    Thread {
                        try {
                            val publicUri = publishToGallery(outputPath)
                            File(outputPath).delete()
                            sendDone(publicUri)
                        } catch (e: Exception) {
                            sendError("ERR_GALLERY", "Export encode mais sauvegarde galerie echouee: ${e.message}")
                        }
                    }.start()
                }

                override fun onError(
                    composition: Composition,
                    exportResult: ExportResult,
                    exportException: ExportException
                ) {
                    sendError("ERR_EXPORT", "Echec de l'export: ${exportException.errorCode} - ${exportException.message}")
                }

                override fun onFallbackApplied(
                    composition: Composition,
                    originalTransformationRequest: TransformationRequest,
                    fallbackTransformationRequest: TransformationRequest
                ) {
                    sendProgress(0.0, "preparing", "Negociation des codecs (fallback applique)")
                }
            })

        if (bitrate > 0) {
            builder.setEncoderFactory(
                DefaultEncoderFactory.Builder(context)
                    .setRequestedVideoEncoderSettings(
                        VideoEncoderSettings.Builder().setBitrate(bitrate).build()
                    )
                    .build()
            )
        }

        transformer = builder.build()
        transformer?.start(composition, outputPath)

        // Polling des progrÃ¨s (Media3 1.4.1 n'a pas de callback de progression direct)
        startProgressPolling()
    }

    fun cancelExport() {
        progressPolling = false
        progressHandler?.removeCallbacksAndMessages(null)
        transformer?.cancel()
        transformer = null
    }

    private fun startProgressPolling() {
        progressPolling = true
        val holder = ProgressHolder()
        val poll = object : Runnable {
            override fun run() {
                if (!progressPolling) return
                val t = transformer ?: return
                val state = t.getProgress(holder)
                val progressPercent = holder.progress.coerceIn(0, 100)
                val progress = progressPercent / 100.0
                sendProgress(progress, "processing", "Export en cours $progressPercent%")
                if (progressPolling) {
                    progressHandler?.postDelayed(this, 200)
                }
            }
        }
        progressHandler = Handler(Looper.getMainLooper())
        progressHandler?.postDelayed(poll, 200)
    }

    private fun parseComposition(json: String): Triple<List<ClipItem>, List<ClipItem>, List<TextItem>> {
        val root = JSONObject(json)
        val texts = mutableListOf<TextItem>()
        val ta = root.optJSONArray("texts")
        if (ta != null) {
            for (i in 0 until ta.length()) {
                val o = ta.getJSONObject(i)
                texts.add(TextItem(
                    o.optString("text", ""), o.optLong("startMs", 0L), o.optLong("durationMs", 0L),
                    o.optLong("color", 0xFFFFFFFFL).toInt(), o.optDouble("size", 56.0), o.optDouble("y", 0.5)
                ))
            }
        }
        return Triple(parseArray(root.optJSONArray("video")), parseArray(root.optJSONArray("audio")), texts)
    }

    private fun parseArray(arr: JSONArray?): List<ClipItem> {
        val list = mutableListOf<ClipItem>()
        if (arr == null) return list
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            list.add(ClipItem(
                o.getString("path"), o.optLong("startMs", 0L), o.optLong("durationMs", 0L),
                o.optDouble("speed", 1.0), o.optDouble("volume", 1.0),
                o.optDouble("brightness", 0.0), o.optDouble("contrast", 0.0),
                o.optDouble("saturation", 0.0), o.optDouble("sepia", 0.0)
            ))
        }
        return list
    }

    /** Applique le rognage (start/duration), la resolution et l'option audio. */
    private fun buildItem(item: ClipItem, removeAudio: Boolean, height: Int, width: Int = 0): EditedMediaItem {
        val uri = if (item.path.contains("://")) Uri.parse(item.path) else Uri.fromFile(File(item.path))
        val mediaItem = MediaItem.Builder().setUri(uri).apply {
            if (item.durationMs > 0) {
                setClippingConfiguration(
                    MediaItem.ClippingConfiguration.Builder()
                        .setStartPositionMs(item.startMs)
                        .setEndPositionMs(item.startMs + item.durationMs)
                        .build()
                )
            }
        }.build()
        val b = EditedMediaItem.Builder(mediaItem).setRemoveAudio(removeAudio)
        val audioProcs = mutableListOf<AudioProcessor>()
        val videoEffects = mutableListOf<Effect>()
        if (item.speed != 1.0) {
            audioProcs.add(SonicAudioProcessor().apply { setSpeed(item.speed.toFloat()) })
            videoEffects.add(SpeedChangeEffect(item.speed.toFloat()))
        }
        if (item.volume != 1.0) {
            val mixer = ChannelMixingAudioProcessor()
            for (ch in 1..2) {
                mixer.putChannelMixingMatrix(ChannelMixingMatrix.create(ch, ch).scaleBy(item.volume.toFloat()))
            }
            audioProcs.add(mixer)
        }
        // Filtres : meme ordre que l'apercu (saturation, sepia, contraste, luminosite).
        if (item.saturation != 0.0) {
            videoEffects.add(HslAdjustment.Builder().adjustSaturation((item.saturation * 100).toFloat()).build())
        }
        if (item.sepia > 0.0) videoEffects.add(SepiaMatrix(item.sepia.toFloat()))
        if (item.contrast != 0.0) videoEffects.add(Contrast(item.contrast.toFloat()))
        if (item.brightness != 0.0) videoEffects.add(Brightness(item.brightness.toFloat()))
        if (height > 0) {
            try {
                if (width > 0) {
                    var added = false
                    val cls = Presentation::class.java
                    for (m in cls.methods) {
                        if (m.name == "createForWidthAndHeight" && java.lang.reflect.Modifier.isStatic(m.modifiers)) {
                            val params = m.parameterTypes
                            try {
                                val effect = when (params.size) {
                                    2 -> m.invoke(null, width, height) as Effect
                                    3 -> {
                                        if (params[2] == Float::class.javaPrimitiveType || params[2] == Float::class.java) {
                                            m.invoke(null, width, height, 1.0f) as Effect
                                        } else {
                                            m.invoke(null, width, height, null) as Effect
                                        }
                                    }
                                    else -> null
                                }
                                if (effect != null) {
                                    videoEffects.add(effect)
                                    added = true
                                    break
                                }
                            } catch (t: Throwable) {
                            }
                        }
                    }
                    if (!added) {
                        videoEffects.add(Presentation.createForHeight(height))
                    }
                } else {
                    videoEffects.add(Presentation.createForHeight(height))
                }
            } catch (e: Throwable) {
                videoEffects.add(Presentation.createForHeight(height))
            }
        }
        if (audioProcs.isNotEmpty() || videoEffects.isNotEmpty()) {
            b.setEffects(Effects(audioProcs, videoEffects))
        }
        return b.build()
    }

    private fun sendProgress(progress: Double, state: String, message: String) {
        val map = JSONObject()
            .put("progress", progress)
            .put("state", state)
            .put("message", message)
        mainHandler.post {
            channel.invokeMethod("progress", map.toString(), null)
        }
    }

    private fun publishToGallery(tempPath: String): String {
        val name = "export_${System.currentTimeMillis()}.mp4"
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, name)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.Video.Media.RELATIVE_PATH, "Movies/EditVideo")
                put(MediaStore.Video.Media.IS_PENDING, 1)
            }
        }
        val resolver = context.contentResolver
        val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("Impossible de creer l'entree MediaStore")
        try {
            resolver.openOutputStream(uri)?.use { out ->
                java.io.FileInputStream(tempPath).use { input ->
                    input.copyTo(out)
                }
            } ?: throw IllegalStateException("OutputStream null")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val doneValues = ContentValues().apply {
                    put(MediaStore.Video.Media.IS_PENDING, 0)
                }
                resolver.update(uri, doneValues, null, null)
            }
            return uri.toString()
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
    }

    private fun sendDone(outputPath: String) {
        progressPolling = false
        progressHandler?.removeCallbacksAndMessages(null)
        val map = JSONObject()
            .put("outputPath", outputPath)
        mainHandler.post {
            channel.invokeMethod("done", map.toString(), null)
        }
    }

    private fun sendError(code: String, message: String) {
        progressPolling = false
        progressHandler?.removeCallbacksAndMessages(null)
        val map = JSONObject()
            .put("code", code)
            .put("message", message)
        mainHandler.post {
            channel.invokeMethod("error", map.toString(), null)
        }
    }

    /** Sepia partiel : melange entre l'identite et la matrice sepia (colonne-major 4x4). */
    private class SepiaMatrix(private val a: Float) : RgbMatrix {
        override fun getMatrix(presentationTimeUs: Long, useHdr: Boolean): FloatArray {
            val r0 = floatArrayOf(1 - a + a * 0.393f, a * 0.769f, a * 0.189f)
            val r1 = floatArrayOf(a * 0.349f, 1 - a + a * 0.686f, a * 0.168f)
            val r2 = floatArrayOf(a * 0.272f, a * 0.534f, 1 - a + a * 0.131f)
            return floatArrayOf(
                r0[0], r1[0], r2[0], 0f,
                r0[1], r1[1], r2[1], 0f,
                r0[2], r1[2], r2[2], 0f,
                0f, 0f, 0f, 1f
            )
        }
    }

    private data class TextItem(
        val text: String, val startMs: Long, val durationMs: Long,
        val color: Int, val size: Double, val y: Double
    )

    /** Texte affiche uniquement pendant [startMs, startMs+durationMs). */
    private class TimedTextOverlay(private val t: TextItem, frameHeight: Int) : TextOverlay() {
        private val shown = SpannableString(t.text).apply {
            val h = if (frameHeight > 0) frameHeight else 720
            val px = (t.size * (h.toDouble() / 720.0)).toInt().coerceAtLeast(16)
            setSpan(ForegroundColorSpan(t.color), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            setSpan(AbsoluteSizeSpan(px), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        private val hidden = SpannableString(" ")

        override fun getText(presentationTimeUs: Long): SpannableString {
            val ms = presentationTimeUs / 1000
            return if (ms >= t.startMs && ms < t.startMs + t.durationMs) shown else hidden
        }

        override fun getOverlaySettings(presentationTimeUs: Long): OverlaySettings =
            OverlaySettings.Builder().setBackgroundFrameAnchor(0.5f, (t.y * 2.0 - 1.0).toFloat()).build()
    }

    private data class ClipItem(
        val path: String,
        val startMs: Long,
        val durationMs: Long,
        val speed: Double = 1.0,
        val volume: Double = 1.0,
        val brightness: Double = 0.0,
        val contrast: Double = 0.0,
        val saturation: Double = 0.0,
        val sepia: Double = 0.0
    )
}
