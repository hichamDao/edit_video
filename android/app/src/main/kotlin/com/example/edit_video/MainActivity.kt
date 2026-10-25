package com.example.edit_video

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity: FlutterActivity() {
    private val VIDEO_METADATA_CHANNEL = "com.example.edit_video/video_metadata"
    private val EXPORT_CHANNEL = "com.example.edit_video/export"
    private var exportService: Media3ExportService? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Pont natif MediaMetadataRetriever (lecture de la durée réelle) ──
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VIDEO_METADATA_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getMetadata" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("ERR_NO_PATH", "path is null", null)
                            return@setMethodCallHandler
                        }
                         try {
                             val meta = JSONObject()
                             val retriever = android.media.MediaMetadataRetriever()
                             retriever.setDataSource(path)
                             retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()?.let {
                                 meta.put("duration", it)
                             }
                             retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()?.let {
                                 meta.put("width", it)
                             }
                             retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()?.let {
                                 meta.put("height", it)
                             }
                             retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toIntOrNull()?.let {
                                 meta.put("bitrate", it)
                             }
                             retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_MIMETYPE)?.let {
                                 meta.put("mimeType", it)
                             }
                             retriever.release()
                             result.success(meta.toString())
                         } catch (e: Exception) {
                            result.error("ERR_READ", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Pont natif Media3 Transformer (export vidéo réel) ──
        val exportChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, EXPORT_CHANNEL)
        exportService = Media3ExportService(this, exportChannel)

        exportChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startExport" -> {
                    val compositionJson = call.argument<String>("composition") ?: "[]"
                    val outputPath = call.argument<String>("outputPath") ?: ""
                    val videoMimeType = call.argument<String>("videoMimeType")
                    val audioMimeType = call.argument<String>("audioMimeType")
                    val outputHeight = call.argument<Int>("outputHeight") ?: 0
                    val bitrate = call.argument<Int>("bitrate") ?: 0
                    val includeAudio = call.argument<Boolean>("includeAudio") ?: true
                    exportService?.startExport(
                        compositionJson = compositionJson,
                        outputPath = outputPath,
                        videoMimeType = videoMimeType,
                        audioMimeType = audioMimeType,
                        outputHeight = outputHeight,
                        bitrate = bitrate,
                        includeAudio = includeAudio
                    )
                    result.success(true)
                }
                "cancelExport" -> {
                    exportService?.cancelExport()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}