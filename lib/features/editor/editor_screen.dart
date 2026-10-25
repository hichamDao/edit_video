import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter/rendering.dart' as rendering;

import '../../core/project_holder.dart';
import '../../models/capcut_models.dart';
import '../../services/segment_service.dart';
import '../../services/video_metadata_service.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final ProjectServiceImpl _projectService = ProjectServiceImpl();
  final VideoMetadataService _metadataService = VideoMetadataService();
  final Uuid _uuid = const Uuid();

  Project? _project;
  VideoPlayerController? _videoController;
  Segment? _selectedSegment;

  Duration _playheadPosition = Duration.zero;

  static const double _trackLabelWidth = 80;
  static const double _pixelsPerSecond = 60;
  static const double _minimumClipWidth = 40;

  @override
  void initState() {
    super.initState();
    _project = _projectService.createProject('Untitled Project');
    ProjectHolder.current = _project;
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  Track? _videoTrack() {
    final project = _project;
    if (project == null || project.tracks.isEmpty) return null;

    for (final track in project.tracks) {
      if (track.type == TrackType.video) return track;
    }

    return project.tracks.first;
  }

  Duration _segmentDuration(Segment segment) {
    return segment.clip?.effectiveDuration ?? segment.timeRange.duration;
  }

  double _clipWidth(Segment segment) {
    return (_segmentDuration(segment).inMilliseconds /
        1000 *
        _pixelsPerSecond)
        .clamp(_minimumClipWidth, double.infinity)
        .toDouble();
  }

  String _formatTime(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    final milliseconds = duration.inMilliseconds % 1000;

    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}.'
        '${milliseconds.toString().padLeft(3, '0')}';
  }

  String _formatShort(Duration duration) {
    return '${duration.inMinutes}:'
        '${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _recomputeTimeline({bool refresh = true}) {
    final project = _project;
    final track = _videoTrack();

    if (project == null || track == null) return;

    var cursor = Duration.zero;

    for (final segment in track.segments) {
      final duration = _segmentDuration(segment);

      segment.timeRange = TimeRange(
        start: cursor,
        duration: duration,
      );

      cursor += duration;
    }

    ProjectHolder.current = project;

    if (refresh && mounted) {
      setState(() {});
    }
  }

  Future<void> _importVideo() async {
    if (_project == null) return;

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: false,
      );

      if (!mounted || result == null || result.files.isEmpty) return;

      final path = result.files.single.path;
      if (path == null) {
        _showMessage('Impossible de lire le chemin de cette vidéo.');
        return;
      }

      final fileName = path.split(RegExp(r'[/\\]')).last;
      final metadata = await _metadataService.readMetadata(path);

      if (!mounted) return;

      final duration = metadata?.duration ?? const Duration(seconds: 5);

      if (duration <= Duration.zero) {
        _showMessage('La durée de la vidéo est invalide.');
        return;
      }

      final clip = Clip(
        id: _uuid.v4(),
        name: fileName,
        assetPath: path,
        sourcePath: path,
        type: ClipType.video,
        duration: duration,
        metadata: metadata != null
            ? {
          'width': metadata.width,
          'height': metadata.height,
          'fps': metadata.fps,
        }
            : const {},
      );

      final segment = Segment(
        id: _uuid.v4(),
        name: fileName,
        timeRange: TimeRange(
          start: Duration.zero,
          duration: duration,
        ),
        clipId: clip.id,
        clip: clip,
      );

      final track = _videoTrack();

      if (track == null) {
        _showMessage('Aucune piste disponible pour la vidéo.');
        return;
      }

      _projectService.addSegment(_project!, track.id, segment);
      _recomputeTimeline(refresh: false);

      setState(() {
        _selectedSegment = segment;
        _playheadPosition = segment.timeRange.start;
      });

      await _playSegment(segment);
    } catch (error, stackTrace) {
      debugPrint('[IMPORT] $error\n$stackTrace');
      _showMessage('Erreur lors de l’importation de la vidéo.');
    }
  }

  void _addEmptySegment() {
    final project = _project;
    final track = _videoTrack();

    if (project == null || track == null) return;

    final segment = Segment(
      id: _uuid.v4(),
      name: 'Clip',
      timeRange: TimeRange(
        start: Duration.zero,
        duration: const Duration(seconds: 5),
      ),
    );

    _projectService.addSegment(project, track.id, segment);
    _recomputeTimeline(refresh: false);

    setState(() {
      _selectedSegment = segment;
      _playheadPosition = segment.timeRange.start;
    });

    ProjectHolder.current = project;
  }

  Future<void> _selectSegment(Segment segment) async {
    setState(() {
      _selectedSegment = segment;
      _playheadPosition = segment.timeRange.start +
          Duration(
            milliseconds: segment.timeRange.duration.inMilliseconds ~/ 2,
          );
    });

    await _playSegment(segment);
  }

  Future<void> _playSegment(Segment segment) async {
    final clip = segment.clip;
    final path = clip?.assetPath;

    if (path == null || path.isEmpty) {
      await _videoController?.dispose();

      if (!mounted) return;

      setState(() {
        _videoController = null;
      });
      return;
    }

    final previousController = _videoController;
    _videoController = null;
    await previousController?.dispose();

    if (!mounted) return;

    final controller = VideoPlayerController.file(File(path));
    _videoController = controller;

    try {
      await controller.initialize();

      if (!mounted || !identical(_videoController, controller)) {
        await controller.dispose();
        return;
      }

      // Commence à la position de rognage du clip sélectionné.
      await controller.seekTo(clip!.trimStart);
      await controller.setPlaybackSpeed(clip.speed);
      await controller.setVolume(clip.volume.clamp(0.0, 1.0).toDouble());

      // Le fichier source est lu en entier : on arrête la lecture à la fin du
      // clip (rognage inclus) et on synchronise la tête de lecture.
      final sourceEnd = clip.trimStart +
          Duration(
              microseconds:
                  (segment.timeRange.duration.inMicroseconds * clip.speed).round());
      controller.addListener(() {
        if (!mounted || !identical(_videoController, controller)) return;
        final value = controller.value;
        if (!value.isPlaying) return;
        var local = Duration(
            microseconds:
                ((value.position - clip.trimStart).inMicroseconds / clip.speed)
                    .round());
        if (value.position >= sourceEnd) {
          controller.pause();
          controller.seekTo(sourceEnd);
          local = segment.timeRange.duration;
        }
        if (local < Duration.zero) local = Duration.zero;
        setState(() {
          _playheadPosition = segment.timeRange.start + local;
        });
      });

      if (!mounted || !identical(_videoController, controller)) {
        await controller.dispose();
        return;
      }

      setState(() {});

      await controller.play();
    } catch (error, stackTrace) {
      debugPrint('[PREVIEW] $error\n$stackTrace');

      if (identical(_videoController, controller)) {
        _videoController = null;
      }

      await controller.dispose();

      if (mounted) {
        setState(() {});
        _showMessage('Impossible de lire cette vidéo.');
      }
    }
  }

  void _moveSegment(Track track, Segment segment, int delta) {
    final oldIndex = track.segments.indexWhere(
          (item) => item.id == segment.id,
    );

    if (oldIndex < 0) return;

    final newIndex = oldIndex + delta;

    if (newIndex < 0 || newIndex >= track.segments.length) return;

    final moved = track.segments.removeAt(oldIndex);
    track.segments.insert(newIndex, moved);

    _recomputeTimeline(refresh: false);

    setState(() {
      _selectedSegment = moved;
      _playheadPosition = moved.timeRange.start;
    });

    ProjectHolder.current = _project;
  }

  void _reorderSegment(Track track, Segment dragged, Segment target) {
    final from = track.segments.indexWhere((s) => s.id == dragged.id);
    final targetIndex = track.segments.indexWhere((s) => s.id == target.id);

    if (from < 0 || targetIndex < 0 || from == targetIndex) return;

    final moved = track.segments.removeAt(from);

    var destination = targetIndex;
    if (from < targetIndex) destination--;

    track.segments.insert(destination, moved);

    _recomputeTimeline(refresh: false);

    setState(() {
      _selectedSegment = moved;
      _playheadPosition = moved.timeRange.start;
    });

    ProjectHolder.current = _project;
  }

  void _splitSelected() {
    final project = _project;
    final selected = _selectedSegment;

    if (project == null || selected == null) return;

    Track? track;

    for (final candidate in project.tracks) {
      if (candidate.segments.any((s) => s.id == selected.id)) {
        track = candidate;
        break;
      }
    }

    if (track == null) {
      _showMessage('Le clip sélectionné est introuvable.');
      return;
    }

    final start = selected.timeRange.start;
    final end = start + selected.timeRange.duration;
    final splitAt = _playheadPosition;

    if (splitAt <= start || splitAt >= end) {
      _showMessage(
        'Place la tête de lecture à l’intérieur du clip sélectionné.',
      );
      return;
    }

    try {
      final parts = _projectService.splitSegmentAt(
        project,
        track.id,
        selected.id,
        splitAt,
      );

      if (parts.length != 2) {
        _showMessage('La découpe n’a pas pu être effectuée à cet endroit.');
        return;
      }

      final rightSegment = parts[1];

      _recomputeTimeline(refresh: false);

      setState(() {
        _selectedSegment = rightSegment;
        _playheadPosition = rightSegment.timeRange.start;
      });

      ProjectHolder.current = project;
    } catch (error, stackTrace) {
      debugPrint('[SPLIT] $error\n$stackTrace');
      _showMessage('La découpe a échoué. Vérifie SegmentService.');
    }
  }

  Future<void> _trimSelected() async {
    final selected = _selectedSegment;
    final clip = selected?.clip;

    if (selected == null || clip == null) {
      _showMessage('Sélectionne un clip vidéo à rogner.');
      return;
    }

    final controller = TextEditingController(
      text: '${clip.trimStart.inMilliseconds},'
          '${clip.trimEnd.inMilliseconds}',
    );

    try {
      final result = await showDialog<List<int>>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Rogner le clip'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Durée source : ${clip.duration.inMilliseconds} ms'),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Début, fin (ms)',
                  hintText: '500,1000',
                  helperText: 'Temps retiré au début et à la fin.',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () {
                final values = controller.text.split(',');
                if (values.length != 2) return;

                final start = int.tryParse(values[0].trim());
                final end = int.tryParse(values[1].trim());

                if (start == null || end == null) return;

                Navigator.pop(dialogContext, [start, end]);
              },
              child: const Text('Appliquer'),
            ),
          ],
        ),
      );

      if (!mounted || result == null) return;

      final durationMs = clip.duration.inMilliseconds;

      if (durationMs <= 0) return;

      final trimStartMs = result[0].clamp(0, durationMs);
      final trimEndMs = result[1].clamp(0, durationMs);

      if (trimStartMs + trimEndMs >= durationMs) {
        _showMessage('Le rognage doit conserver une durée positive.');
        return;
      }

      clip.trimStart = Duration(milliseconds: trimStartMs);
      clip.trimEnd = Duration(milliseconds: trimEndMs);

      _recomputeTimeline(refresh: false);

      setState(() {
        _playheadPosition = selected.timeRange.start;
      });

      ProjectHolder.current = _project;
    } finally {
      controller.dispose();
    }
  }

  double _timelineWidth() {
    final project = _project;
    if (project == null) return 400;

    var total = Duration.zero;

    for (final track in project.tracks) {
      if (track.type != TrackType.video) continue;

      for (final segment in track.segments) {
        total += _segmentDuration(segment);
      }
    }

    final contentWidth =
        total.inMilliseconds / 1000 * _pixelsPerSecond;

    return _trackLabelWidth + contentWidth + 200;
  }

  Widget _buildTimelineRuler(double width) {
    final totalSeconds = (width / _pixelsPerSecond).ceil();

    return Container(
      height: 28,
      color: Colors.grey.shade900,
      child: Row(
        children: [
          Container(
            width: _trackLabelWidth,
            alignment: Alignment.center,
            color: Colors.grey.shade800,
            child: const Text(
              'Temps',
              style: TextStyle(color: Colors.white70, fontSize: 10),
            ),
          ),
          ...List.generate(
            totalSeconds,
                (index) => SizedBox(
              width: _pixelsPerSecond,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${index}s',
                  style: const TextStyle(
                    color: Colors.grey,
                    fontSize: 10,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrack(Track track, double timelineWidth) {
    final isVideoTrack = track.type == TrackType.video;

    return SizedBox(
      height: 64,
      child: Container(
        color: Colors.grey.shade900,
        child: Stack(
          clipBehavior: rendering.Clip.none,
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: _trackLabelWidth,
              child: Container(
                color: Colors.grey.shade800,
                alignment: Alignment.center,
                padding: const EdgeInsets.all(4),
                child: Text(
                  track.name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                  ),
                ),
              ),
            ),
            ...track.segments.map((segment) {
              final selected = _selectedSegment?.id == segment.id;
              final clipWidth = _clipWidth(segment);

              final left = _trackLabelWidth +
                  segment.timeRange.start.inMilliseconds /
                      1000 *
                      _pixelsPerSecond;

              return Positioned(
                key: ValueKey('segment_${segment.id}'),
                left: left,
                top: 8,
                bottom: 8,
                child: DragTarget<Segment>(
                  onWillAcceptWithDetails: (details) =>
                  details.data.id != segment.id &&
                      track.segments.any((s) => s.id == details.data.id),
                  onAcceptWithDetails: (details) {
                    _reorderSegment(track, details.data, segment);
                  },
                  builder: (context, candidates, rejected) {
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _selectSegment(segment),
                      child: LongPressDraggable<Segment>(
                        data: segment,
                        dragAnchorStrategy: pointerDragAnchorStrategy,
                        onDragStarted: () {
                          setState(() {
                            _selectedSegment = segment;
                          });
                        },
                        feedback: Material(
                          color: Colors.transparent,
                          child: Container(
                            width: clipWidth,
                            height: 48,
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.blueAccent.withOpacity(0.95),
                              borderRadius: BorderRadius.circular(5),
                              border: Border.all(color: Colors.white),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              segment.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ),
                        childWhenDragging: Container(
                          width: clipWidth,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade700,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        child: Container(
                          width: clipWidth,
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(
                            color: candidates.isNotEmpty
                                ? Colors.amber
                                : selected
                                ? Colors.blueAccent
                                : isVideoTrack
                                ? Colors.blue.shade700
                                : Colors.green.shade700,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: selected
                                  ? Colors.white
                                  : Colors.white.withOpacity(0.3),
                              width: selected ? 2 : 1,
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                segment.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 8,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                _formatShort(_segmentDuration(segment)),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 8,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              );
            }),
            if (isVideoTrack)
              Positioned(
                left: _trackLabelWidth +
                    _playheadPosition.inMilliseconds /
                        1000 *
                        _pixelsPerSecond,
                top: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Container(
                    width: 2,
                    color: Colors.redAccent,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayheadControls() {
    final selected = _selectedSegment;

    if (selected == null) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          'Sélectionne un clip pour déplacer la tête de lecture et le scinder.',
          style: TextStyle(color: Colors.white70, fontSize: 12),
          textAlign: TextAlign.center,
        ),
      );
    }

    final start = selected.timeRange.start.inMilliseconds.toDouble();
    final end = (selected.timeRange.start +
        selected.timeRange.duration)
        .inMilliseconds
        .toDouble();

    final maxValue = end > start ? end : start + 1;
    final currentValue = _playheadPosition.inMilliseconds
        .toDouble()
        .clamp(start, maxValue)
        .toDouble();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(
                Icons.linear_scale,
                size: 18,
                color: Colors.redAccent,
              ),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'Tête de lecture',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
              Text(
                _formatTime(_playheadPosition),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          Slider(
            min: start,
            max: maxValue,
            value: currentValue,
            activeColor: Colors.redAccent,
            onChanged: (value) {
              setState(() {
                _playheadPosition =
                    Duration(milliseconds: value.round());
              });
            },
          ),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: selected.clip == null ||
                  selected.timeRange.duration <
                      const Duration(milliseconds: 2)
                  ? null
                  : _splitSelected,
              icon: const Icon(Icons.content_cut),
              label: const Text('Scinder à la tête de lecture'),
            ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────── Texte ─────────────────────────

  Track _textTrack() {
    final project = _project!;
    for (final t in project.tracks) {
      if (t.type == TrackType.text) return t;
    }
    final track = Track(id: _uuid.v4(), name: 'Texte 1', type: TrackType.text);
    project.addTrack(track);
    return track;
  }

  bool _isText(Segment? s) => s?.clip?.type == ClipType.text;

  void _addText() {
    if (_project == null) return;
    final track = _textTrack();
    final start = _playheadPosition;
    const dur = Duration(seconds: 3);
    final clip = Clip(
      id: _uuid.v4(),
      name: 'Texte',
      assetPath: '',
      type: ClipType.text,
      duration: dur,
      properties: {'text': 'Votre texte', 'color': 0xFFFFFFFF, 'size': 56, 'y': 0.5},
    );
    final segment = Segment(
      id: _uuid.v4(),
      name: 'Texte',
      timeRange: TimeRange(start: start, duration: dur),
      clipId: clip.id,
      clip: clip,
    );
    _projectService.addSegment(_project!, track.id, segment);
    ProjectHolder.current = _project;
    setState(() => _selectedSegment = segment);
    _editText();
  }

  Future<void> _editText() async {
    final seg = _selectedSegment;
    final clip = seg?.clip;
    if (seg == null || clip == null || clip.type != ClipType.text) return;
    final props = clip.properties;
    final controller = TextEditingController(text: '${props['text'] ?? ''}');
    var size = ((props['size'] ?? 56) as num).toDouble();
    var y = ((props['y'] ?? 0.5) as num).toDouble();
    var color = (props['color'] ?? 0xFFFFFFFF) as int;
    var seconds = seg.timeRange.duration.inMilliseconds / 1000;
    const colors = [0xFFFFFFFF, 0xFFFFEB3B, 0xFFFF5252, 0xFF40C4FF, 0xFF69F0AE, 0xFF000000];

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setL) => AlertDialog(
          title: const Text('Texte'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: controller, autofocus: true, maxLines: 2),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                for (final c in colors)
                  GestureDetector(
                    onTap: () => setL(() => color = c),
                    child: CircleAvatar(
                      radius: 14,
                      backgroundColor: Color(c),
                      child: color == c ? const Icon(Icons.check, size: 16, color: Colors.grey) : null,
                    ),
                  ),
              ]),
              Text('Taille : ${size.round()}'),
              Slider(min: 20, max: 140, value: size, onChanged: (v) => setL(() => size = v)),
              Text('Position verticale : ${(y * 100).round()} %'),
              Slider(min: 0.05, max: 0.95, value: y, onChanged: (v) => setL(() => y = v)),
              Text('Durée : ${seconds.toStringAsFixed(1)} s'),
              Slider(min: 0.5, max: 15, value: seconds.clamp(0.5, 15.0).toDouble(), onChanged: (v) => setL(() => seconds = v)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
          ],
        ),
      ),
    );
    final text = controller.text;
    controller.dispose();
    if (ok != true || !mounted) return;
    final dur = Duration(milliseconds: (seconds * 1000).round());
    props['text'] = text.isEmpty ? ' ' : text;
    props['size'] = size.round();
    props['y'] = y;
    props['color'] = color;
    seg.timeRange = TimeRange(start: seg.timeRange.start, duration: dur);
    setState(() {});
    ProjectHolder.current = _project;
  }

  /// Superpose les textes actifs à la position de la tête de lecture.
  Widget _previewWithText(Widget base) {
    final project = _project;
    final overlays = <Widget>[];
    if (project != null) {
      for (final track in project.tracks) {
        if (track.type != TrackType.text) continue;
        for (final seg in track.segments) {
          final start = seg.timeRange.start;
          final end = start + seg.timeRange.duration;
          if (_playheadPosition < start || _playheadPosition >= end) continue;
          final p = seg.clip?.properties ?? const {};
          final y = ((p['y'] ?? 0.5) as num).toDouble();
          final size = ((p['size'] ?? 56) as num).toDouble();
          overlays.add(Align(
            alignment: Alignment(0, y * 2 - 1),
            child: LayoutBuilder(builder: (context, c) {
              final scale = (MediaQuery.of(context).size.height * 0.3) / 720;
              return Text(
                '${p['text'] ?? ''}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: size * scale * 2,
                  fontWeight: FontWeight.bold,
                  color: Color((p['color'] ?? 0xFFFFFFFF) as int),
                  shadows: const [Shadow(blurRadius: 4, color: Colors.black)],
                ),
              );
            }),
          ));
        }
      }
    }
    return Stack(fit: StackFit.expand, children: [base, ...overlays]);
  }

  // ───────────────────────── Filtres ─────────────────────────

  List<double> _mul5(List<double> a, List<double> b) {
    final r = List<double>.filled(25, 0);
    for (var i = 0; i < 5; i++) {
      for (var j = 0; j < 5; j++) {
        var v = 0.0;
        for (var k = 0; k < 5; k++) {
          v += a[i * 5 + k] * b[k * 5 + j];
        }
        r[i * 5 + j] = v;
      }
    }
    return r;
  }

  /// Matrice couleur 4x5 (Flutter ColorFilter.matrix) : saturation → sépia → contraste → luminosité.
  List<double> _filterMatrix(Clip c) {
    List<double> identity() => [
          1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1
        ];
    final s = 1 + c.saturation;
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final sat = identity();
    sat.setAll(0, [
      lr * (1 - s) + s, lg * (1 - s), lb * (1 - s), 0, 0,
      lr * (1 - s), lg * (1 - s) + s, lb * (1 - s), 0, 0,
      lr * (1 - s), lg * (1 - s), lb * (1 - s) + s, 0, 0,
    ]);
    final a = c.sepia.clamp(0.0, 1.0).toDouble();
    final sep = identity();
    sep.setAll(0, [
      1 - a + a * 0.393, a * 0.769, a * 0.189, 0, 0,
      a * 0.349, 1 - a + a * 0.686, a * 0.168, 0, 0,
      a * 0.272, a * 0.534, 1 - a + a * 0.131, 0, 0,
    ]);
    final k = 1 + c.contrast;
    final off = (0.5 - 0.5 * k) * 255;
    final con = identity();
    con[0] = k; con[6] = k; con[12] = k;
    con[4] = off; con[9] = off; con[14] = off;
    final bri = identity();
    bri[4] = c.brightness * 255; bri[9] = c.brightness * 255; bri[14] = c.brightness * 255;
    final m = _mul5(bri, _mul5(con, _mul5(sep, sat)));
    return m.sublist(0, 20);
  }

  Future<void> _editFilters() async {
    final seg = _selectedSegment;
    final clip = seg?.clip;
    if (seg == null || clip == null || clip.type == ClipType.text) return;

    void preset(double b, double c, double s, double sp) {
      clip.brightness = b;
      clip.contrast = c;
      clip.saturation = s;
      clip.sepia = sp;
    }

    final presets = <String, List<double>>{
      'Original': [0, 0, 0, 0],
      'N&B': [0, 0.1, -1, 0],
      'Sépia': [0, 0, 0, 1],
      'Chaud': [0.05, 0, 0.2, 0.35],
      'Vif': [0, 0.2, 0.5, 0],
      'Drame': [-0.05, 0.4, -0.3, 0],
      'Fondu': [0.08, -0.25, -0.2, 0],
    };

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setL) {
          void update(VoidCallback f) {
            setL(f);
            setState(() {});
          }

          Widget slider(String label, double v, double min, double max, void Function(double) on) {
            return Row(children: [
              SizedBox(width: 90, child: Text(label)),
              Expanded(
                child: Slider(
                  min: min, max: max, value: v.clamp(min, max).toDouble(),
                  onChanged: (x) => update(() => on(x)),
                ),
              ),
            ]);
          }

          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  for (final e in presets.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        label: Text(e.key),
                        onPressed: () => update(() => preset(e.value[0], e.value[1], e.value[2], e.value[3])),
                      ),
                    ),
                ]),
              ),
              slider('Luminosité', clip.brightness, -1, 1, (x) => clip.brightness = x),
              slider('Contraste', clip.contrast, -1, 1, (x) => clip.contrast = x),
              slider('Saturation', clip.saturation, -1, 1, (x) => clip.saturation = x),
              slider('Sépia', clip.sepia, 0, 1, (x) => clip.sepia = x),
              FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
            ]),
          );
        },
      ),
    );
    ProjectHolder.current = _project;
    if (mounted) setState(() {});
  }

  // ─────────────────── Vitesse et volume ───────────────────

  Future<void> _editSpeedVolume() async {
    final seg = _selectedSegment;
    final clip = seg?.clip;
    if (seg == null || clip == null || clip.type == ClipType.text) return;
    var speed = clip.speed;
    var volume = clip.volume;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setL) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Vitesse : ${speed.toStringAsFixed(2)}x'),
            Slider(
              min: 0.25, max: 4, divisions: 15, value: speed.clamp(0.25, 4.0).toDouble(),
              onChanged: (v) => setL(() => speed = v),
            ),
            Text('Volume : ${(volume * 100).round()} %'),
            Slider(
              min: 0, max: 2, divisions: 20, value: volume.clamp(0.0, 2.0).toDouble(),
              onChanged: (v) => setL(() => volume = v),
            ),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Appliquer')),
          ]),
        ),
      ),
    );
    if (!mounted) return;
    clip.speed = speed;
    clip.volume = volume;
    _recomputeTimeline(refresh: false);
    final c = _videoController;
    if (c != null && c.value.isInitialized) {
      await c.setPlaybackSpeed(speed);
      await c.setVolume(volume.clamp(0.0, 1.0).toDouble());
    }
    setState(() => _playheadPosition = seg.timeRange.start);
    ProjectHolder.current = _project;
  }

  void _deleteSelected() {
    final seg = _selectedSegment;
    final project = _project;
    if (seg == null || project == null) return;
    for (final t in project.tracks) {
      if (t.segments.any((x) => x.id == seg.id)) {
        _projectService.removeSegment(project, t.id, seg.id);
        break;
      }
    }
    _selectedSegment = null;
    _recomputeTimeline();
  }

  // Barre d'actions : défilement horizontal pour éviter le débordement.
  Widget _buildActions() {
    final selected = _selectedSegment;

    final track = selected == null
        ? null
        : _project?.tracks.cast<Track?>().firstWhere(
          (t) => t!.segments.any((s) => s.id == selected.id),
      orElse: () => null,
    );

    final index = track == null
        ? -1
        : track.segments.indexWhere((s) => s.id == selected?.id);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
        horizontal: 8,
        vertical: 8,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton.icon(
            onPressed: _importVideo,
            icon: const Icon(Icons.video_library, size: 18),
            label: const Text('Importer'),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: _addEmptySegment,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Clip vide'),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: _addText,
            icon: const Icon(Icons.title, size: 18),
            label: const Text('Texte'),
          ),
          if (_isText(selected)) ...[
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: _editText,
              icon: const Icon(Icons.edit, size: 18),
              label: const Text('Modifier'),
            ),
          ],
          if (selected != null && !_isText(selected) && selected.clip != null) ...[
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: _editSpeedVolume,
              icon: const Icon(Icons.speed, size: 18),
              label: const Text('Vitesse/Volume'),
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: _editFilters,
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: const Text('Filtres'),
            ),
          ],
          if (selected != null) ...[
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: 'Supprimer',
              onPressed: _deleteSelected,
              icon: const Icon(Icons.delete),
            ),
          ],
          if (selected != null && track != null) ...[
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: 'Déplacer vers la gauche',
              onPressed: index > 0
                  ? () => _moveSegment(track, selected, -1)
                  : null,
              icon: const Icon(Icons.arrow_back),
            ),
            IconButton.filledTonal(
              tooltip: 'Déplacer vers la droite',
              onPressed: index >= 0 && index < track.segments.length - 1
                  ? () => _moveSegment(track, selected, 1)
                  : null,
              icon: const Icon(Icons.arrow_forward),
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: selected.clip != null ? _trimSelected : null,
              icon: const Icon(Icons.content_cut, size: 18),
              label: const Text('Rogner'),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final project = _project;
    final controller = _videoController;
    final timelineWidth = _timelineWidth();

    return Scaffold(
      appBar: AppBar(
        title: const Text('REA — Éditeur vidéo'),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            tooltip: 'Exporter',
            icon: const Icon(
              Icons.file_download,
              color: Colors.white,
            ),
            onPressed: () {
              Navigator.pushNamed(context, '/export');
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 3,
            child: _previewWithText(Container(
              width: double.infinity,
              color: Colors.black,
              child: controller != null && controller.value.isInitialized
                  ? Center(
                child: AspectRatio(
                  aspectRatio: controller.value.aspectRatio,
                  child: (_selectedSegment?.clip?.hasFilters ?? false)
                      ? ColorFiltered(
                          colorFilter: ColorFilter.matrix(_filterMatrix(_selectedSegment!.clip!)),
                          child: VideoPlayer(controller),
                        )
                      : VideoPlayer(controller),
                ),
              )
                  : const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.play_circle_outline,
                      size: 64,
                      color: Colors.white24,
                    ),
                    SizedBox(height: 12),
                    Text(
                      'Sélectionne un clip pour le prévisualiser',
                      style: TextStyle(
                        color: Colors.grey,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            )),
          ),
          const Divider(height: 1, color: Colors.grey),
          Expanded(
            flex: 3,
            child: project == null
                ? const SizedBox.shrink()
                : Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: timelineWidth.clamp(400.0, 1000000.0),
                      child: Column(
                        children: [
                          _buildTimelineRuler(timelineWidth),
                          Expanded(
                            child: ListView.builder(
                              itemCount: project.tracks.length,
                              itemBuilder: (context, index) {
                                return _buildTrack(
                                  project.tracks[index],
                                  timelineWidth,
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                _buildPlayheadControls(),
                const Divider(height: 1),
                _buildActions(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}