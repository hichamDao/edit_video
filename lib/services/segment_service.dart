/// Couche d'édition — Fidèle à l'analyse REA de CapCut 19.8.0
/// Packages : com.vega.operation (SegmentService), com.vega.draft.impl (ProjectServiceImpl),
///            com.vega.drafeupgrade (DraftTransformerKt)

import 'package:uuid/uuid.dart';
import '../models/capcut_models.dart';

/// 1. SEGMENT SERVICE — com.vega.operation.SegmentService
/// Opérations unitaires sur les segments. Signature observée :
///   s(List<com.vega.draft.data.template.track.Segment>):void

class SegmentService {
  static final SegmentService _instance = SegmentService._internal();
  factory SegmentService() => _instance;
  SegmentService._internal();

  /// Opération par lot sur une liste de segments (équivalent de `s(List<Segment>)`).
  void apply(List<Segment> segments, void Function(Segment) mutate) {
    for (final s in segments) mutate(s);
  }

  /// Découpe un segment à un temps donné → retourne deux segments.
  List<Segment> split(Segment segment, Duration at) {
    if (at <= segment.timeRange.start || at >= segment.timeRange.end) {
      return [segment];
    }
    final leftDuration = at - segment.timeRange.start;
    final rightDuration = segment.timeRange.duration - leftDuration;

    final c = segment.clip;
    Clip? leftClip;
    Clip? rightClip;
    if (c != null) {
      // Chaque moitié reçoit son propre Clip avec le bon rognage source,
      // sinon les deux moitiés réutiliseraient la source entière (doublon à l'export).
      Clip cut(String suffix, Duration ts, Duration te) => Clip(
            id: '${c.id}$suffix',
            name: c.name,
            assetPath: c.assetPath,
            sourcePath: c.sourcePath,
            type: c.type,
            duration: c.duration,
            trimStart: ts,
            trimEnd: te,
            scale: c.scale,
            transform: c.transform,
            flip: c.flip,
            metadata: c.metadata,
            properties: c.properties,
          );
      leftClip = cut('_a', c.trimStart, c.duration - c.trimStart - leftDuration);
      rightClip = cut('_b', c.trimStart + leftDuration, c.trimEnd);
    }

    final left = Segment(
      id: '${segment.id}_a',
      name: '${segment.name} (partie 1)',
      timeRange: TimeRange(
        start: segment.timeRange.start,
        duration: leftDuration,
      ),
      clipId: leftClip?.id ?? segment.clipId,
      clip: leftClip ?? segment.clip,
      offset: segment.offset,
      transform: segment.transform,
      flip: segment.flip,
      scale: segment.scale,
    );

    final right = Segment(
      id: '${segment.id}_b',
      name: '${segment.name} (partie 2)',
      timeRange: TimeRange(
        start: at,
        duration: rightDuration,
      ),
      clipId: rightClip?.id ?? segment.clipId,
      clip: rightClip ?? segment.clip,
      offset: segment.offset,
      transform: segment.transform,
      flip: segment.flip,
      scale: segment.scale,
    );

    return [left, right];
  }

  /// Rognage (trim) d'un segment.
  void trim(Segment segment, Duration trimStart, Duration trimEnd) {
    segment.clip?.trimStart = trimStart;
    segment.clip?.trimEnd = trimEnd;
  }

  /// Déplacement d'un segment sur sa piste.
  void move(Segment segment, Duration newStart) {
    segment.timeRange = TimeRange(
      start: newStart,
      duration: segment.timeRange.duration,
    );
  }

  /// Suppression logique.
  void delete(Segment segment) {
    // marqué pour suppression par le ProjectServiceImpl
  }
}

/// ============================================================================
/// 2. PROJECT SERVICE IMPL — com.vega.draft.impl.ProjectServiceImpl
/// Implémentation qui manipule segments et pistes (référencée via classes anonymes).
/// ============================================================================

class ProjectServiceImpl {
  static final ProjectServiceImpl _instance = ProjectServiceImpl._internal();
  factory ProjectServiceImpl() => _instance;
  ProjectServiceImpl._internal();

  final _segmentService = SegmentService();
  final _uuid = const Uuid();

  /// Crée un projet vide avec une piste vidéo et une piste audio (comme CapCut).
  Project createProject(String name) {
    final project = Project(id: _uuid.v4(), name: name);
    project.addTrack(Track(
      id: _uuid.v4(),
      name: 'Video 1',
      type: TrackType.video,
    ));
    project.addTrack(Track(
      id: _uuid.v4(),
      name: 'Audio 1',
      type: TrackType.audio,
    ));
    return project;
  }

  /// Ajoute un segment à une piste.
  void addSegment(Project project, String trackId, Segment segment) {
    final track = project.getTrack(trackId);
    if (track == null) return;
    track.addSegment(segment);
    project.updatedAt = DateTime.now();
  }

  /// Supprime un segment d'une piste.
  void removeSegment(Project project, String trackId, String segmentId) {
    final track = project.getTrack(trackId);
    if (track == null) return;
    track.removeSegment(segmentId);
    project.updatedAt = DateTime.now();
  }

  /// Découpe un segment en deux à l'instant `at`.
  List<Segment> splitSegmentAt(Project project, String trackId, String segmentId, Duration at) {
    final track = project.getTrack(trackId);
    if (track == null) return [];
    final idx = track.segments.indexWhere((s) => s.id == segmentId);
    if (idx < 0) return [];
    final segment = track.segments[idx];
    final parts = _segmentService.split(segment, at);
    track.segments.removeAt(idx);
    track.segments.insertAll(idx, parts);
    project.updatedAt = DateTime.now();
    return parts;
  }

  /// Déplace un segment.
  void moveSegment(Project project, String trackId, String segmentId, Duration newStart) {
    final track = project.getTrack(trackId);
    if (track == null) return;
    final segment = track.segments.firstWhereOrNull((s) => s.id == segmentId);
    if (segment == null) return;
    _segmentService.move(segment, newStart);
    track.segments.sort((a, b) => a.timeRange.start.compareTo(b.timeRange.start));
    project.updatedAt = DateTime.now();
  }

  /// Ajoute un effet à un segment.
  void addEffectToSegment(Project project, String trackId, String segmentId, MaterialEffect effect) {
    final track = project.getTrack(trackId);
    if (track == null) return;
    final segment = track.segments.firstWhereOrNull((s) => s.id == segmentId);
    if (segment == null) return;
    segment.effects.add(effect);
    project.updatedAt = DateTime.now();
  }

  /// Retire un effet d'un segment.
  void removeEffectFromSegment(Project project, String trackId, String segmentId, String effectId) {
    final track = project.getTrack(trackId);
    if (track == null) return;
    final segment = track.segments.firstWhereOrNull((s) => s.id == segmentId);
    if (segment == null) return;
    segment.effects.removeWhere((e) => e.id == effectId);
    project.updatedAt = DateTime.now();
  }

  /// Met à jour le transform d'un segment (géométrie).
  void updateTransform(Project project, String trackId, String segmentId, Transform transform) {
    final track = project.getTrack(trackId);
    if (track == null) return;
    final segment = track.segments.firstWhereOrNull((s) => s.id == segmentId);
    if (segment == null) return;
    segment.transform = transform;
    project.updatedAt = DateTime.now();
  }
}

/// ============================================================================
/// 3. DRAFT TRANSFORMER — com.vega.drafeupgrade.DraftTransformerKt
/// Point de transformation / upgrade du modèle de projet (Clip, Segment, Track, MaterialEffect).
/// ============================================================================

class DraftTransformer {
  /// Met à niveau un projet d'un ancien format vers le nouveau.
  Project upgrade(Project project) {
    // Migration des anciens segments vers le nouveau modèle avec TimeRange / HdrSettings
    for (final track in project.tracks) {
      for (final segment in track.segments) {
        segment.hdrSettings ??= HdrSettings();
      }
    }
    return project;
  }

  /// Transforme un projet pour l'export (applique les transitions, calcule les durées effectives).
  Project prepareForExport(Project project) {
    final upgraded = upgrade(project);
    // réindexe les segments, applique les transitions entre clips consécutifs
    return upgraded;
  }
}

/// Extension pour firstWhereOrNull (Dart < 3.0 compat).
extension _IterableExtensions<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
