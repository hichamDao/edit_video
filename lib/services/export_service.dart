/// Chaîne d'export — Pont natif Media3 Transformer (Android) via MethodChannel.
/// L'export réel est exécuté côté Kotlin (Media3 1.4.1) ; ce service Dart envoie la
/// composition sérialisée et reçoit les événements de progression / fin / erreur.
/// Compatible hors Android (Web/Desktop) : le service tombe en mode "non disponible"
/// et l'UI affiche un message explicite.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import '../models/capcut_models.dart';
import 'segment_service.dart';

/// Résultat d'une tentative d'export.
enum ExportStatus { idle, preparing, processing, completed, failed, unsupported }

/// Événement de progression d'export.
class ExportProgress {
  final double progress;
  final ExportStatus status;
  final int frame;
  final int totalFrames;
  final String? message;

  ExportProgress({
    required this.progress,
    required this.status,
    this.frame = 0,
    this.totalFrames = 0,
    this.message,
  });
}

/// Résultat d'un export.
class ExportResult {
  final bool success;
  final String? outputPath;
  final String? error;

  ExportResult({required this.success, this.outputPath, this.error});
}

/// Configuration d'export vidéo.
class ExportVideoConfig {
  int width = 1920;
  int height = 1080;
  int bitrate = 8000000;
  int fps = 30;
  String? videoMimeType; // ex: 'video/avc1'
  String? audioMimeType; // ex: 'audio/mp4a'
  int outputHeight = 0; // 0 = auto
  bool includeAudio = true;

  ExportVideoConfig();

  Map<String, dynamic> toJson() {
    return {
      'width': width,
      'height': height,
      'bitrate': bitrate,
      'fps': fps,
      'videoMimeType': videoMimeType,
      'audioMimeType': audioMimeType,
      'outputHeight': outputHeight,
      'includeAudio': includeAudio,
    };
  }
}

/// Service d'export — envoie la composition au pont natif Media3.
class ExportService {
  static const _channel = MethodChannel('com.example.edit_video/export');
  static final ExportService _instance = ExportService._internal();
  factory ExportService() => _instance;
  ExportService._internal() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'progress':
        final raw = call.arguments as String?;
        if (raw != null) {
          final m = jsonDecode(raw) as Map<String, dynamic>;
          final p = (m['progress'] as num?)?.toDouble() ?? 0.0;
          final state = m['state'] as String? ?? 'processing';
          final msg = m['message'] as String?;
          ExportStatus st = ExportStatus.processing;
          if (state == 'preparing') st = ExportStatus.preparing;
          if (state == 'completed') st = ExportStatus.completed;
          if (state == 'failed') st = ExportStatus.failed;
          _emit(ExportProgress(progress: p, status: st, message: msg));
        }
        break;
      case 'done':
        final raw = call.arguments as String?;
        String? out;
        if (raw != null) {
          final m = jsonDecode(raw) as Map<String, dynamic>;
          out = m['outputPath'] as String?;
        }
        _outputPath = out ?? _outputPath;
        _emit(ExportProgress(progress: 1.0, status: ExportStatus.completed, message: 'Export termine'));
        break;
      case 'error':
        final raw = call.arguments as String?;
        String? msg;
        if (raw != null) {
          final m = jsonDecode(raw) as Map<String, dynamic>;
          msg = m['message'] as String?;
        }
        _emit(ExportProgress(progress: 0.0, status: ExportStatus.failed, message: msg ?? 'Erreur export'));
        break;
    }
    return null;
  }

  ExportStatus _status = ExportStatus.idle;
  double _progress = 0.0;
  String? _message;
  String? _outputPath;
  final _controller = StreamController<ExportProgress>.broadcast();
  final _sub = <StreamSubscription>[];

  ExportStatus get status => _status;
  double get progress => _progress;
  String? get message => _message;
  String? get outputPath => _outputPath;
  Stream<ExportProgress> get stream => _controller.stream;

  bool get _isNativeAvailable => Platform.isAndroid;

  bool _closed = false;
  Completer<ExportResult>? _pending;

  void _emit(ExportProgress p) {
    if (_closed || _controller.isClosed) return;
    _status = p.status;
    _progress = p.progress;
    _message = p.message;
    _controller.add(p);
  }

  /// Point d'entrée de l'export — envoie la composition au pont natif Media3.
  Future<ExportResult> exportProject({
    required Project project,
    required String outputPath,
    ExportVideoConfig? config,
    void Function(ExportProgress)? onProgress,
  }) async {
    final cfg = config ?? ExportVideoConfig();

    if (!_isNativeAvailable) {
      _emit(ExportProgress(
        progress: 0.0,
        status: ExportStatus.unsupported,
        message: 'Export natif Media3 indisponible sur cette plateforme',
      ));
      return ExportResult(success: false, error: 'Plateforme non supportée');
    }

    // Sérialise la composition depuis les pistes du projet.
    final composition = _buildComposition(project);

    _emit(ExportProgress(
      progress: 0.0,
      status: ExportStatus.preparing,
      message: 'Préparation de l\'export (Media3 Transformer)...',
    ));

    final completer = Completer<ExportResult>();
    _pending = completer;
    late StreamSubscription sub;
    sub = _controller.stream.listen((p) {
      onProgress?.call(p);
      if (p.status == ExportStatus.completed) {
        // _outputPath contient l'URI galerie renvoyé par le natif (événement 'done').
        completer.complete(ExportResult(success: true, outputPath: _outputPath ?? outputPath));
        sub.cancel();
      } else if (p.status == ExportStatus.failed) {
        completer.complete(ExportResult(success: false, error: p.message));
        sub.cancel();
      }
    });

    try {
      await _channel.invokeMethod('startExport', {
        'composition': composition,
        'outputPath': outputPath,
        'videoMimeType': cfg.videoMimeType,
        'audioMimeType': cfg.audioMimeType,
        'outputHeight': cfg.outputHeight > 0 ? cfg.outputHeight : cfg.height,
        'bitrate': cfg.bitrate,
        'includeAudio': cfg.includeAudio,
      });
    } catch (e) {
      _emit(ExportProgress(
        progress: 0.0,
        status: ExportStatus.failed,
        message: 'Pont natif indisponible: $e',
      ));
      if (!completer.isCompleted) {
        completer.complete(ExportResult(success: false, error: e.toString()));
      }
      return completer.future;
    }

    return completer.future;
  }

  /// Annule l'export en cours.
  void cancel() {
    _sub.forEach((s) => s.cancel());
    _sub.clear();
    _channel.invokeMethod('cancelExport').catchError((_) {});
    _emit(ExportProgress(
      progress: 0.0,
      status: ExportStatus.idle,
      message: 'Annulé',
    ));
    final p = _pending;
    if (p != null && !p.isCompleted) {
      p.complete(ExportResult(success: false, error: 'Annulé'));
    }
  }

  void dispose() {
    _closed = true;
    _sub.forEach((s) => s.cancel());
    _sub.clear();
    if (!_controller.isClosed) {
      _controller.close();
    }
  }

  /// Construit la composition JSON : {"video":[...], "audio":[...]}.
  /// Chaque entrée = { path, startMs (début source), durationMs }.
  /// Les pistes audio sont jouées en parallèle de la vidéo (séquence séparée).
  String _buildComposition(Project project) {
    final video = <Map<String, dynamic>>[];
    final audio = <Map<String, dynamic>>[];
    for (final track in project.tracks) {
      final isVideo = track.type == TrackType.video;
      if (!isVideo && track.type != TrackType.audio) continue;
      final ordered = [...track.segments]
        ..sort((a, b) => a.timeRange.start.compareTo(b.timeRange.start));
      for (final seg in ordered) {
        final clip = seg.clip;
        final path = clip?.assetPath ?? clip?.sourcePath;
        if (clip == null || path == null || path.isEmpty) continue;
        final effective = clip.effectiveDuration;
        if (effective <= Duration.zero) continue;
        (isVideo ? video : audio).add({
          'path': path,
          'startMs': clip.trimStart.inMilliseconds,
          'durationMs': effective.inMilliseconds,
        });
      }
    }
    return jsonEncode({'video': video, 'audio': audio});
  }
}
