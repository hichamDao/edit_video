/// Service pour lire les métadonnées d'un fichier vidéo via le pont natif Android.
/// Utilise `MediaMetadataRetriever` (API 21+, donc compatible minSdk 21+).
/// Aucune dépendance tierce : communication via MethodChannel standard Flutter.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import '../models/capcut_models.dart';

/// Lit les métadonnées d'un fichier vidéo via le pont natif Android
/// (`MediaMetadataRetriever`). Retourne `null` si le fichier n'existe pas ou si la
/// lecture échoue (le code natif est tolerant).
class VideoMetadataService {
  static const _channel = MethodChannel('com.example.edit_video/video_metadata');
  static final VideoMetadataService _instance = VideoMetadataService._internal();
  factory VideoMetadataService() => _instance;
  VideoMetadataService._internal();

  /// Lit les métadonnées d'un fichier vidéo.
  Future<VideoMetadata?> readMetadata(String path) async {
    if (path.isEmpty) return null;
    final file = File(path);
    if (!await file.exists()) return null;

    try {
      final result = await _channel.invokeMethod<String>(
        'getMetadata',
        <String, dynamic>{'path': path},
      );
      if (result == null || result.isEmpty) return null;
      final map = jsonDecode(result) as Map<String, dynamic>;
      return VideoMetadata(
        sourceType: map['mimeType'] as String? ?? 'video',
        width: (map['width'] as int?) ?? 0,
        height: (map['height'] as int?) ?? 0,
        fps: (map['fps'] as double?) ?? 0.0,
        duration: Duration(milliseconds: (map['duration'] as int?) ?? 0),
      );
    } catch (_) {
      return null;
    }
  }
}