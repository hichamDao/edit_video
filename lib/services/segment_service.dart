// Couche d'édition — Service des segments vidéo.
// Découpe, rognage, déplacement et préparation du projet à l'export.

import 'package:uuid/uuid.dart';
import '../models/capcut_models.dart';

// ============================================================================
// 1. SEGMENT SERVICE
// ============================================================================

class SegmentService {
  static final SegmentService _instance = SegmentService._internal();

  factory SegmentService() => _instance;

  SegmentService._internal();

  final Uuid _uuid = const Uuid();

  /// Applique une opération à plusieurs segments.
  void apply(
      List<Segment> segments,
      void Function(Segment) mutate,
      ) {
    for (final segment in segments) {
      mutate(segment);
    }
  }

  /// Découpe un segment à une position absolue de la timeline.
  ///
  /// Exemple : une vidéo de 10 secondes coupée à 2 secondes donne :
  /// - Partie 1 : 0 à 2 secondes.
  /// - Partie 2 : 2 à 10 secondes.
  ///
  /// Les deux clips conservent le chemin du fichier source original,
  /// mais possèdent des trimStart et trimEnd distincts.
  List<Segment> split(Segment segment, Duration at) {
    final timelineStart = segment.timeRange.start;
    final timelineDuration = segment.timeRange.duration;
    final timelineEnd = timelineStart + timelineDuration;

    if (at <= timelineStart || at >= timelineEnd) {
      return [segment];
    }

    final leftDuration = at - timelineStart;
    final rightDuration = timelineEnd - at;
    final originalClip = segment.clip;

    if (originalClip == null) {
      return [segment];
    }

    final sourceDuration = originalClip.duration;
    final sourceStart = originalClip.trimStart;
    final sourceEnd = sourceDuration - originalClip.trimEnd;

    if (sourceStart < Duration.zero ||
        originalClip.trimEnd < Duration.zero ||
        sourceEnd <= sourceStart) {
      return [segment];
    }

    // Coupe dans la source, à vitesse de lecture normale (1x).
    final speed = originalClip.speed <= 0 ? 1.0 : originalClip.speed;
    final sourceCut = sourceStart +
        Duration(microseconds: (leftDuration.inMicroseconds * speed).round());

    if (sourceCut <= sourceStart || sourceCut >= sourceEnd) {
      return [segment];
    }

    // Partie 1 : début de la source jusqu'au point de coupe.
    final leftClip = Clip(
      id: _uuid.v4(),
      name: '${originalClip.name} (partie 1)',
      assetPath: originalClip.assetPath,
      sourcePath: originalClip.sourcePath,
      type: originalClip.type,
      duration: sourceDuration,
      trimStart: sourceStart,
      trimEnd: sourceDuration - sourceCut,
      scale: originalClip.scale,
      transform: originalClip.transform,
      flip: originalClip.flip,
      metadata: Map<String, dynamic>.from(originalClip.metadata),
      properties: Map<String, dynamic>.from(originalClip.properties),
      speed: originalClip.speed,
      volume: originalClip.volume,
    );

    // Partie 2 : point de coupe jusqu'à la fin de la plage source.
    final rightClip = Clip(
      id: _uuid.v4(),
      name: '${originalClip.name} (partie 2)',
      assetPath: originalClip.assetPath,
      sourcePath: originalClip.sourcePath,
      type: originalClip.type,
      duration: sourceDuration,
      trimStart: sourceCut,
      trimEnd: originalClip.trimEnd,
      scale: originalClip.scale,
      transform: originalClip.transform,
      flip: originalClip.flip,
      metadata: Map<String, dynamic>.from(originalClip.metadata),
      properties: Map<String, dynamic>.from(originalClip.properties),
      speed: originalClip.speed,
      volume: originalClip.volume,
    );

    Segment createPart({
      required String name,
      required Duration start,
      required Duration duration,
      required Clip clip,
    }) {
      return Segment(
        id: _uuid.v4(),
        name: name,
        timeRange: TimeRange(
          start: start,
          duration: duration,
        ),
        clipId: clip.id,
        clip: clip,
        offset: segment.offset,
        effects: List<MaterialEffect>.from(segment.effects),
        hdrSettings: segment.hdrSettings,
        enableAnimation: segment.enableAnimation,
        enableStabilization: segment.enableStabilization,
        enableMatting: segment.enableMatting,
        enableSpeedCurve: segment.enableSpeedCurve,
        isPlaceholder: segment.isPlaceholder,
        volume: segment.volume,
        muted: segment.muted,
        transform: segment.transform,
        flip: segment.flip,
        scale: segment.scale,
        keyframes: Map<String, dynamic>.from(segment.keyframes),
        properties: Map<String, dynamic>.from(segment.properties),
      );
    }

    final left = createPart(
      name: '${segment.name} (partie 1)',
      start: timelineStart,
      duration: leftDuration,
      clip: leftClip,
    );

    final right = createPart(
      name: '${segment.name} (partie 2)',
      start: at,
      duration: rightDuration,
      clip: rightClip,
    );

    return [left, right];
  }

  /// Rogne un clip en conservant une durée positive.
  void trim(
      Segment segment,
      Duration trimStart,
      Duration trimEnd,
      ) {
    final clip = segment.clip;

    if (clip == null) return;
    if (trimStart < Duration.zero || trimEnd < Duration.zero) return;
    if (trimStart + trimEnd >= clip.duration) return;

    clip.trimStart = trimStart;
    clip.trimEnd = trimEnd;

    segment.timeRange = TimeRange(
      start: segment.timeRange.start,
      duration: clip.effectiveDuration,
    );
  }

  /// Déplace un segment sur la timeline.
  void move(Segment segment, Duration newStart) {
    segment.timeRange = TimeRange(
      start: newStart,
      duration: segment.timeRange.duration,
    );
  }

  /// La suppression effective est gérée par ProjectServiceImpl.
  void delete(Segment segment) {}
}

/// ============================================================================
/// 2. PROJECT SERVICE IMPL
/// ============================================================================

class ProjectServiceImpl {
  static final ProjectServiceImpl _instance =
  ProjectServiceImpl._internal();

  factory ProjectServiceImpl() => _instance;

  ProjectServiceImpl._internal();

  final SegmentService _segmentService = SegmentService();
  final Uuid _uuid = const Uuid();

  /// Recherche un segment sans utiliser firstWhereOrNull.
  /// Cette méthode évite l'erreur de compilation signalée.
  Segment? _findSegment(Track track, String segmentId) {
    for (final segment in track.segments) {
      if (segment.id == segmentId) {
        return segment;
      }
    }
    return null;
  }

  /// Crée un projet avec une piste vidéo et une piste audio.
  Project createProject(String name) {
    final project = Project(
      id: _uuid.v4(),
      name: name,
    );

    project.addTrack(
      Track(
        id: _uuid.v4(),
        name: 'Video 1',
        type: TrackType.video,
      ),
    );

    project.addTrack(
      Track(
        id: _uuid.v4(),
        name: 'Audio 1',
        type: TrackType.audio,
      ),
    );

    return project;
  }

  /// Ajoute un segment à une piste.
  void addSegment(
      Project project,
      String trackId,
      Segment segment,
      ) {
    final track = project.getTrack(trackId);
    if (track == null) return;

    track.addSegment(segment);
    project.updatedAt = DateTime.now();
  }

  /// Supprime un segment d'une piste.
  void removeSegment(
      Project project,
      String trackId,
      String segmentId,
      ) {
    final track = project.getTrack(trackId);
    if (track == null) return;

    track.removeSegment(segmentId);
    project.updatedAt = DateTime.now();
  }

  /// Scinde un segment et remplace l'original par les deux parties.
  List<Segment> splitSegmentAt(
      Project project,
      String trackId,
      String segmentId,
      Duration at,
      ) {
    final track = project.getTrack(trackId);
    if (track == null) return [];

    final index = track.segments.indexWhere(
          (segment) => segment.id == segmentId,
    );

    if (index < 0) return [];

    final original = track.segments[index];
    final parts = _segmentService.split(original, at);

    // Ne remplace pas l'original si la découpe a échoué.
    if (parts.length != 2) return parts;

    track.segments
      ..removeAt(index)
      ..insertAll(index, parts);

    track.segments.sort(
          (a, b) => a.timeRange.start.compareTo(b.timeRange.start),
    );

    project.updatedAt = DateTime.now();

    return parts;
  }

  /// Déplace un segment.
  void moveSegment(
      Project project,
      String trackId,
      String segmentId,
      Duration newStart,
      ) {
    final track = project.getTrack(trackId);
    if (track == null) return;

    final segment = _findSegment(track, segmentId);
    if (segment == null) return;

    _segmentService.move(segment, newStart);

    track.segments.sort(
          (a, b) => a.timeRange.start.compareTo(b.timeRange.start),
    );

    project.updatedAt = DateTime.now();
  }

  /// Ajoute un effet à un segment.
  void addEffectToSegment(
      Project project,
      String trackId,
      String segmentId,
      MaterialEffect effect,
      ) {
    final track = project.getTrack(trackId);
    if (track == null) return;

    final segment = _findSegment(track, segmentId);
    if (segment == null) return;

    segment.effects.add(effect);
    project.updatedAt = DateTime.now();
  }

  /// Supprime un effet d'un segment.
  void removeEffectFromSegment(
      Project project,
      String trackId,
      String segmentId,
      String effectId,
      ) {
    final track = project.getTrack(trackId);
    if (track == null) return;

    final segment = _findSegment(track, segmentId);
    if (segment == null) return;

    segment.effects.removeWhere(
          (effect) => effect.id == effectId,
    );

    project.updatedAt = DateTime.now();
  }

  /// Met à jour la transformation géométrique d'un segment.
  void updateTransform(
      Project project,
      String trackId,
      String segmentId,
      Transform transform,
      ) {
    final track = project.getTrack(trackId);
    if (track == null) return;

    final segment = _findSegment(track, segmentId);
    if (segment == null) return;

    segment.transform = transform;
    project.updatedAt = DateTime.now();
  }
}

/// ============================================================================
/// 3. DRAFT TRANSFORMER
/// ============================================================================

class DraftTransformer {
  /// Met à niveau les paramètres d'un projet.
  Project upgrade(Project project) {
    for (final track in project.tracks) {
      for (final segment in track.segments) {
        segment.hdrSettings ??= HdrSettings();
      }
    }

    return project;
  }

  /// Prépare le projet avant l'export.
  Project prepareForExport(Project project) {
    return upgrade(project);
  }
}
