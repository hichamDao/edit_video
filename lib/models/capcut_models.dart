/// Modèle de données — Fidèle à l'analyse REA de CapCut 19.8.0
/// Packages : com.vega.draft.data.template (Project, Track, Segment, Clip, Material, ...)

/// Racine du document de montage — `com.vega.draft.data.template.Project`
/// Référencée par 86 xrefs (point de fuite maximal du moteur).
class Project {
  final String id;
  String name;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<Track> tracks;
  final Map<String, dynamic> settings;
  final Map<String, dynamic> extraInfo;  // template.extraInfo (29 classes)
  final VideoMetadata? videoMetadata;
  final String? draftPath;               // chemin du projet sur disque

  Project({
    required this.id,
    required this.name,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<Track>? tracks,
    Map<String, dynamic>? settings,
    Map<String, dynamic>? extraInfo,
    this.videoMetadata,
    this.draftPath,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        tracks = tracks ?? [],
        settings = settings ?? {},
        extraInfo = extraInfo ?? {};

  void addTrack(Track track) {
    tracks.add(track);
    updatedAt = DateTime.now();
  }

  void removeTrack(String trackId) {
    tracks.removeWhere((t) => t.id == trackId);
    updatedAt = DateTime.now();
  }

  Track? getTrack(String id) {
    try {
      return tracks.firstWhere((t) => t.id == id);
    } catch (_) {
      return null;
    }
  }

  List<Segment> getAllSegments() {
    final segs = <Segment>[];
    for (final t in tracks) segs.addAll(t.segments);
    return segs;
  }

  Duration get duration {
    Duration max = Duration.zero;
    for (final t in tracks) {
      for (final s in t.segments) {
        final end = s.timeRange.start + s.timeRange.duration + s.offset;
        if (end > max) max = end;
      }
    }
    return max;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'tracks': tracks.map((t) => t.toJson()).toList(),
      'settings': settings,
      'extraInfo': extraInfo,
      'draftPath': draftPath,
    };
  }
}

/// Alias historique CapCut (com.draft.ve.data / com.vega.draft.impl)
typedef Draft = Project;

/// Piste — `com.vega.draft.data.template.track.Track`
/// 8 méthodes, 5 champs, interne `Flag`.
class Track {
  final String id;
  String name;
  TrackType type;
  bool muted;
  bool locked;
  bool visible;
  double volume;
  final int flag;           // interne Track.Flag
  final List<Segment> segments;

  Track({
    required this.id,
    required this.name,
    required this.type,
    this.muted = false,
    this.locked = false,
    this.visible = true,
    this.volume = 1.0,
    this.flag = 0,
    List<Segment>? segments,
  }) : segments = segments ?? [];

  void addSegment(Segment segment) {
    segments.add(segment);
    segments.sort((a, b) => a.timeRange.start.compareTo(b.timeRange.start));
  }

  void removeSegment(String id) {
    segments.removeWhere((s) => s.id == id);
  }

  Segment? segmentAt(Duration time) {
    for (final s in segments) {
      if (time >= s.timeRange.start && time < s.timeRange.start + s.timeRange.duration) {
        return s;
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type.index,
      'muted': muted,
      'locked': locked,
      'visible': visible,
      'volume': volume,
      'flag': flag,
      'segments': segments.map((s) => s.toJson()).toList(),
    };
  }
}

enum TrackType { video, audio, text, image, effect }

/// Segment — `com.vega.draft.data.template.track.Segment`
/// 27 champs, constructeur principal à 26 paramètres, internes TimeRange + HdrSettings.
class Segment {
  final String id;
  String name;
  TimeRange timeRange;       // plage temporelle (start, duration)
  Duration offset;           // décalage sur la piste
  final String? clipId;            // référence au Clip (matériau)
  final Clip? clip;                // matériau embarqué (dénormalisé)
  final List<MaterialEffect> effects;   // liste de filtres/effets
  HdrSettings? hdrSettings;  // interne HdrSettings
  final bool enableAnimation;
  final bool enableStabilization;
  final bool enableMatting;
  final bool enableSpeedCurve;
  final bool isPlaceholder;
  final double volume;
  final bool muted;
  Transform transform;       // interne Transform (scale, rotation, position)
  final Flip flip;                 // interne Flip
  final Scale scale;               // interne Scale
  final Map<String, dynamic> keyframes;  // animations par paramètre
  final Map<String, dynamic> properties;

  Segment({
    required this.id,
    required this.name,
    required this.timeRange,
    this.offset = Duration.zero,
    this.clipId,
    this.clip,
    List<MaterialEffect>? effects,
    this.hdrSettings,
    this.enableAnimation = false,
    this.enableStabilization = false,
    this.enableMatting = false,
    this.enableSpeedCurve = false,
    this.isPlaceholder = false,
    this.volume = 1.0,
    this.muted = false,
    Transform? transform,
    Flip? flip,
    Scale? scale,
    Map<String, dynamic>? keyframes,
    Map<String, dynamic>? properties,
  })  : effects = effects ?? [],
        transform = transform ?? Transform.identity(),
        flip = flip ?? Flip.none(),
        scale = scale ?? Scale.one(),
        keyframes = keyframes ?? {},
        properties = properties ?? {};

  Duration get startTime => timeRange.start;
  Duration get duration => timeRange.duration;
  Duration get endTime => timeRange.end;
  Duration get absoluteStart => startTime + offset;
  Duration get absoluteEnd => absoluteStart + duration;

  bool contains(Duration time) =>
      time >= absoluteStart && time < absoluteEnd;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'timeRange': timeRange.toJson(),
      'offset': offset.inMilliseconds,
      'clipId': clipId,
      'effects': effects.map((e) => e.toJson()).toList(),
      'hdrSettings': hdrSettings?.toJson(),
      'enableAnimation': enableAnimation,
      'enableStabilization': enableStabilization,
      'enableMatting': enableMatting,
      'enableSpeedCurve': enableSpeedCurve,
      'isPlaceholder': isPlaceholder,
      'volume': volume,
      'muted': muted,
      'transform': transform.toJson(),
      'flip': flip.toJson(),
      'scale': scale.toJson(),
      'keyframes': keyframes,
      'properties': properties,
    };
  }
}

/// Plage temporelle — interne de Segment.
class TimeRange {
  final Duration start;
  final Duration duration;

  TimeRange({required this.start, required this.duration});

  Duration get end => start + duration;

  Map<String, dynamic> toJson() {
    return {'start': start.inMilliseconds, 'duration': duration.inMilliseconds};
  }
}

/// Réglages HDR — interne de Segment.
class HdrSettings {
  final bool enabled;
  final double brightness;
  final double contrast;
  final double saturation;

  HdrSettings({
    this.enabled = false,
    this.brightness = 1.0,
    this.contrast = 1.0,
    this.saturation = 1.0,
  });

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'brightness': brightness,
      'contrast': contrast,
      'saturation': saturation,
    };
  }
}

/// Transform — interne de Segment (géométrie + timecodes, voir VEClipInfo).
class Transform {
  final double scaleX;
  final double scaleY;
  final double rotation;
  final double offsetX;
  final double offsetY;
  final double anchorX;
  final double anchorY;

  Transform({
    this.scaleX = 1.0,
    this.scaleY = 1.0,
    this.rotation = 0.0,
    this.offsetX = 0.0,
    this.offsetY = 0.0,
    this.anchorX = 0.5,
    this.anchorY = 0.5,
  });

  factory Transform.identity() => Transform();

  Map<String, dynamic> toJson() {
    return {
      'scaleX': scaleX, 'scaleY': scaleY, 'rotation': rotation,
      'offsetX': offsetX, 'offsetY': offsetY,
      'anchorX': anchorX, 'anchorY': anchorY,
    };
  }
}

/// Flip — interne de Segment.
class Flip {
  final bool horizontal;
  final bool vertical;

  Flip({this.horizontal = false, this.vertical = false});

  factory Flip.none() => Flip();
  factory Flip.horizontal() => Flip(horizontal: true);
  factory Flip.vertical() => Flip(vertical: true);
  factory Flip.both() => Flip(horizontal: true, vertical: true);

  Map<String, dynamic> toJson() {
    return {'horizontal': horizontal, 'vertical': vertical};
  }
}

/// Scale — interne de Segment.
class Scale {
  final double x;
  final double y;

  Scale({this.x = 1.0, this.y = 1.0});

  factory Scale.one() => Scale();

  Map<String, dynamic> toJson() => {'x': x, 'y': y};
}

/// Clip / Matériau — `com.vega.draft.data.template.material.Material`
/// Sérialisation kotlinx.serialization (CompositeEncoder).
class Clip {
  final String id;
  String name;
  final String assetPath;
  final String? sourcePath;      // chemin fichier original
  final ClipType type;
  final Duration duration;       // durée source
  Duration trimStart;      // rognage début
  Duration trimEnd;        // rognage fin
  final Scale scale;             // internes Scale
  final Transform transform;     // internes Transform
  final Flip flip;               // internes Flip
  final Map<String, dynamic> metadata;  // VideoMetadata embarqué
  final Map<String, dynamic> properties;

  Clip({
    required this.id,
    required this.name,
    required this.assetPath,
    this.sourcePath,
    required this.type,
    this.duration = Duration.zero,
    this.trimStart = Duration.zero,
    this.trimEnd = Duration.zero,
    Scale? scale,
    Transform? transform,
    Flip? flip,
    Map<String, dynamic>? metadata,
    Map<String, dynamic>? properties,
  })  : scale = scale ?? Scale.one(),
        transform = transform ?? Transform.identity(),
        flip = flip ?? Flip.none(),
        metadata = metadata ?? {},
        properties = properties ?? {};

  Duration get effectiveDuration =>
      duration - trimStart - trimEnd;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'assetPath': assetPath,
      'sourcePath': sourcePath,
      'type': type.index,
      'duration': duration.inMilliseconds,
      'trimStart': trimStart.inMilliseconds,
      'trimEnd': trimEnd.inMilliseconds,
      'scale': scale.toJson(),
      'transform': transform.toJson(),
      'flip': flip.toJson(),
      'metadata': metadata,
      'properties': properties,
    };
  }
}

enum ClipType { video, audio, text, image }

/// Effet de matériau — `com.vega.draft.data.template.material.MaterialEffect`
/// 14 méthodes, 23 champs ; fabriqueur `i(...)`.
class MaterialEffect {
  final String id;
  String name;
  final String effectType;      // "filter", "transition", "sticker", ...
  final String? assetPath;
  final Map<String, dynamic> params;
  final bool isPreset;
  final int order;

  MaterialEffect({
    required this.id,
    required this.name,
    required this.effectType,
    this.assetPath,
    Map<String, dynamic>? params,
    this.isPreset = false,
    this.order = 0,
  }) : params = params ?? {};

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'effectType': effectType,
      'assetPath': assetPath,
      'params': params,
      'isPreset': isPreset,
      'order': order,
    };
  }
}

/// Transition de matériau — `com.vega.draft.data.template.material.MaterialTransition`
/// 13 méthodes.
class MaterialTransition {
  final String id;
  String name;
  final String transitionType;  // "fade", "slide", "dissolve", ...
  final Duration duration;
  final String? assetPath;

  MaterialTransition({
    required this.id,
    required this.name,
    required this.transitionType,
    this.duration = const Duration(milliseconds: 300),
    this.assetPath,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'transitionType': transitionType,
      'duration': duration.inMilliseconds,
      'assetPath': assetPath,
    };
  }
}

/// Métadonnées vidéo — `com.draft.ve.data.VideoMetadata`
class VideoMetadata {
  final String sourceType;
  final Map<String, dynamic> douyinMetadata;  // DouyinMetadata
  final int? oplustag;
  final int width;
  final int height;
  final double fps;
  final Duration duration;

  VideoMetadata({
    required this.sourceType,
    this.douyinMetadata = const {},
    this.oplustag,
    required this.width,
    required this.height,
    required this.fps,
    required this.duration,
  });
}

/// VEClipInfo — `com.draft.ve.data.VEClipInfo`
/// Géométrie + timecodes (float,float,float,float,int,long,long,bool,bool,int).
class VEClipInfo {
  final double left;
  final double top;
  final double right;
  final double bottom;
  final int rotate;
  final int startTimeMs;
  final int endTimeMs;
  final bool isMirror;
  final bool isFlip;
  final int zOrder;

  VEClipInfo({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.rotate,
    required this.startTimeMs,
    required this.endTimeMs,
    this.isMirror = false,
    this.isFlip = false,
    this.zOrder = 0,
  });
}
