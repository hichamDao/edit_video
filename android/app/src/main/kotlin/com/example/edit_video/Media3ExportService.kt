package com.example.edit_video

import android.content.Context
import android.content.ContentValues
import android.os.Build
import android.provider.MediaStore
import android.net.Uri
import androidx.media3.common.Effects
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
 * Pont natif Media3 Transformer — exécute un export vidéo réel.
 *
 * API cible : Media3 1.4.1 (minSdk 19). La configuration d'export passe par
 * `Transformer.Builder.setTransformationRequest(TransformationRequest)` (dépréciée mais
 * publiquement accessible en 1.4.1). Les paramètres avancés (outputHeight, MIME types)
 * sont passés via le Builder interne.
 *
 * Communication : MethodChannel "com.example.edit_video/export".
 * Entrées (JSON) :
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
        includeAudio: Boolean = true
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
        if (videoItems.isEmpty() && audioItems.isEmpty()) {
            sendError("ERR_EMPTY", "Aucun clip dans la composition")
            return
        }

        val sequences = mutableListOf<EditedMediaItemSequence>()
        if (videoItems.isNotEmpty()) {
            sequences.add(EditedMediaItemSequence(
                videoItems.map { buildItem(it, !includeAudio, outputHeight) }))
        }
        if (audioItems.isNotEmpty() && includeAudio) {
            sequences.add(EditedMediaItemSequence(
                audioItems.map { buildItem(it, false, 0) }))
        }
        if (sequences.isEmpty()) {
            sendError("ERR_EMPTY", "Aucune piste a exporter (audio desactive)")
            return
        }
        val composition = Composition.Builder(sequences).build()

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

        // Polling des progrès (Media3 1.4.1 n'a pas de callback de progression direct)
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

    private fun parseComposition(json: String): Pair<List<ClipItem>, List<ClipItem>> {
        val root = JSONObject(json)
        return Pair(parseArray(root.optJSONArray("video")), parseArray(root.optJSONArray("audio")))
    }

    private fun parseArray(arr: JSONArray?): List<ClipItem> {
        val list = mutableListOf<ClipItem>()
        if (arr == null) return list
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            list.add(ClipItem(o.getString("path"), o.optLong("startMs", 0L), o.optLong("durationMs", 0L)))
        }
        return list
    }

    /** Applique le rognage (start/duration), la resolution et l'option audio. */
    private fun buildItem(item: ClipItem, removeAudio: Boolean, height: Int): EditedMediaItem {
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
        if (height > 0) {
            b.setEffects(Effects(listOf(), listOf(Presentation.createForHeight(height))))
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

    private data class ClipItem(
        val path: String,
        val startMs: Long,
        val durationMs: Long
    )
}