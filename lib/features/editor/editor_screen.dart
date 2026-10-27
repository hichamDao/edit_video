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

  bool _textEditingMode = false;
  String? _editingTextSegmentId;
  TextEditingController? _inlineTextController;
  FocusNode? _inlineTextFocusNode;
  Segment? _tempTextSegment;
  final GlobalKey _previewKey = GlobalKey();

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
    _inlineTextController?.dispose();
    _inlineTextFocusNode?.dispose();
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
      await _selectSegment(selected); // recharge l'aperçu avec la nouvelle plage
    } finally {
      // Le dialog joue encore son animation de fermeture : disposer tout de
      // suite le controller du TextField provoque l'écran rouge.
      Future.delayed(const Duration(milliseconds: 500), controller.dispose);
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

              final isTextSegment = segment.clip?.type.toString() == 'ClipType.text';
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
                    return LongPressDraggable<Segment>(
                      data: segment,
                      dragAnchorStrategy: pointerDragAnchorStrategy,
                      onDragStarted: () {
                        if (_textEditingMode) {
                          _cancelInlineTextEdit(removeTemp: true);
                        }
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
                      child: Stack(
                        clipBehavior: rendering.Clip.none,
                        children: [
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              if (_textEditingMode) return;
                              _selectSegment(segment);
                            },
                            // Texte : glisser horizontalement change son temps de début.
                            onHorizontalDragUpdate: isTextSegment
                                ? (details) {
                                    if (_textEditingMode) return;
                                    final deltaMs =
                                        (details.delta.dx / _pixelsPerSecond * 1000).round();
                                    final newStart = Duration(
                                        milliseconds: (segment.timeRange.start.inMilliseconds + deltaMs)
                                            .clamp(0, 1 << 30));
                                    setState(() {
                                      _selectedSegment = segment;
                                      segment.timeRange = TimeRange(
                                          start: newStart, duration: segment.timeRange.duration);
                                      _playheadPosition = newStart;
                                    });
                                    ProjectHolder.current = _project;
                                  }
                                : null,
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
                          if (isTextSegment && selected)
                            Positioned(
                              left: -4,
                              top: 0,
                              bottom: 0,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onPanUpdate: (details) {
                                  final dx = details.delta.dx / _pixelsPerSecond;
                                  var deltaMs = (dx * 1000).round();
                                  if (deltaMs == 0) return;
                                  final startMs = segment.timeRange.start.inMilliseconds;
                                  final durMs = segment.timeRange.duration.inMilliseconds;
                                  var newStartMs = startMs + deltaMs;
                                  var newDurMs = durMs - deltaMs;
                                  if (newDurMs < 500) {
                                    newDurMs = 500;
                                    newStartMs = startMs + durMs - 500;
                                  }
                                  if (newStartMs < 0) {
                                    newStartMs = 0;
                                    newDurMs = startMs + durMs;
                                    if (newDurMs < 500) newDurMs = 500;
                                  }
                                  segment.timeRange = TimeRange(
                                    start: Duration(milliseconds: newStartMs),
                                    duration: Duration(milliseconds: newDurMs),
                                  );
                                  _recomputeTimeline(refresh: false);
                                  ProjectHolder.current = _project;
                                  if (mounted) setState(() {});
                                },
                                child: Container(
                                  width: 8,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.9),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                            ),
                          if (isTextSegment && selected)
                            Positioned(
                              right: -4,
                              top: 0,
                              bottom: 0,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onPanUpdate: (details) {
                                  final dx = details.delta.dx / _pixelsPerSecond;
                                  var deltaMs = (dx * 1000).round();
                                  if (deltaMs == 0) return;
                                  final durMs = segment.timeRange.duration.inMilliseconds;
                                  var newDurMs = durMs + deltaMs;
                                  if (newDurMs < 500) newDurMs = 500;
                                  if (newDurMs > 15000) newDurMs = 15000;
                                  segment.timeRange = TimeRange(
                                    start: segment.timeRange.start,
                                    duration: Duration(milliseconds: newDurMs),
                                  );
                                  _recomputeTimeline(refresh: false);
                                  ProjectHolder.current = _project;
                                  if (mounted) setState(() {});
                                },
                                child: Container(
                                  width: 8,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.9),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                            ),
                        ],
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
                    color: const Color(0xFFFF5A64),
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
    final start = selected?.timeRange.start.inMilliseconds.toDouble() ?? 0.0;
    final end = selected == null
        ? 1.0
        : (selected.timeRange.start + selected.timeRange.duration)
            .inMilliseconds
            .toDouble();
    final maxValue = end > start ? end : start + 1;
    final currentValue = _playheadPosition.inMilliseconds
        .toDouble()
        .clamp(start, maxValue)
        .toDouble();

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 5, 12, 9),
      decoration: const BoxDecoration(
        color: Color(0xFF111216),
        border: Border(top: BorderSide(color: Color(0xFF292A2F))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFF27292E),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _formatTime(_playheadPosition),
                  style: const TextStyle(
                    color: Color(0xFFB8F64A),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'TÊTE DE LECTURE',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Scinder au curseur',
                visualDensity: VisualDensity.compact,
                onPressed: selected?.clip == null ||
                        selected!.timeRange.duration <
                            const Duration(milliseconds: 2)
                    ? null
                    : _splitSelected,
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFFB8F64A),
                  foregroundColor: const Color(0xFF11130B),
                  disabledBackgroundColor: const Color(0xFF292A2F),
                  disabledForegroundColor: Colors.white24,
                ),
                icon: const Icon(Icons.content_cut_rounded, size: 18),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: const Color(0xFFB8F64A),
              inactiveTrackColor: const Color(0xFF393B40),
              thumbColor: const Color(0xFFB8F64A),
              overlayColor: const Color(0x22B8F64A),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              min: start,
              max: maxValue,
              value: currentValue,
              onChanged: selected == null
                  ? null
                  : (value) {
                      setState(() {
                        _playheadPosition = Duration(milliseconds: value.round());
                      });
                    },
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

  void _cancelInlineTextEdit({bool removeTemp = true}) {
    if (_textEditingMode && removeTemp && _tempTextSegment != null && _project != null) {
      for (final t in _project!.tracks) {
        if (t.segments.any((x) => x.id == _tempTextSegment!.id)) {
          _projectService.removeSegment(_project!, t.id, _tempTextSegment!.id);
          break;
        }
      }
      _recomputeTimeline(refresh: false);
      ProjectHolder.current = _project;
    }
    _inlineTextFocusNode?.unfocus();
    final controller = _inlineTextController;
    final focusNode = _inlineTextFocusNode;
    _inlineTextController = null;
    _inlineTextFocusNode = null;
    _textEditingMode = false;
    _editingTextSegmentId = null;
    _tempTextSegment = null;
    _selectedSegment = null;
    if (mounted) {
      setState(() {});
    }
    if (controller != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.dispose();
      });
    }
    if (focusNode != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        focusNode.dispose();
      });
    }
  }

  void _commitInlineTextEdit() {
    if (!_textEditingMode || _editingTextSegmentId == null) return;
    final seg = _selectedSegment;
    final clip = seg?.clip;
    if (seg == null || clip == null || clip.type != ClipType.text) {
      _cancelInlineTextEdit(removeTemp: false);
      return;
    }
    final props = clip.properties;
    final text = _inlineTextController?.text ?? '';
    props['text'] = text.isEmpty ? ' ' : text;
    if (!props.containsKey('color')) props['color'] = 0xFFFFFFFF;
    if (!props.containsKey('size')) props['size'] = 56;
    if (!props.containsKey('y')) props['y'] = 0.5;
    _tempTextSegment = null;
    _inlineTextFocusNode?.unfocus();
    final controller = _inlineTextController;
    final focusNode = _inlineTextFocusNode;
    _inlineTextController = null;
    _inlineTextFocusNode = null;
    _textEditingMode = false;
    _editingTextSegmentId = null;
    if (mounted) {
      setState(() {
        _selectedSegment = seg;
      });
    } else {
      _selectedSegment = seg;
    }
    ProjectHolder.current = _project;
    if (controller != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.dispose();
      });
    }
    if (focusNode != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        focusNode.dispose();
      });
    }
  }

  void _addText() {
    if (_project == null) return;
    if (_textEditingMode) {
      _cancelInlineTextEdit(removeTemp: true);
    }
    final track = _textTrack();
    final start = _playheadPosition;
    const dur = Duration(seconds: 3);
    final clip = Clip(
      id: _uuid.v4(),
      name: 'Texte',
      assetPath: '',
      type: ClipType.text,
      duration: dur,
      properties: {'text': '', 'color': 0xFFFFFFFF, 'size': 56, 'y': 0.5},
    );
    final segment = Segment(
      id: _uuid.v4(),
      name: 'Texte',
      timeRange: TimeRange(start: start, duration: dur),
      clipId: clip.id,
      clip: clip,
    );
    _projectService.addSegment(_project!, track.id, segment);
    _recomputeTimeline(refresh: false);
    _tempTextSegment = segment;
    _selectedSegment = segment;
    _editingTextSegmentId = segment.id;
    _inlineTextController?.dispose();
    _inlineTextFocusNode?.dispose();
    _inlineTextController = TextEditingController(text: '');
    _inlineTextFocusNode = FocusNode();
    _textEditingMode = true;
    ProjectHolder.current = _project;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _textEditingMode && _inlineTextFocusNode != null) {
        FocusScope.of(context).requestFocus(_inlineTextFocusNode);
      }
    });
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
    if (ok != true || !mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.dispose();
      });
      return;
    }
    final dur = Duration(milliseconds: (seconds * 1000).round());
    if (props.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.dispose();
      });
      return;
    }
    props['text'] = text.isEmpty ? ' ' : text;
    props['size'] = size.round();
    props['y'] = y;
    props['color'] = color;
    if (seg.timeRange.start < Duration.zero) {
      seg.timeRange = TimeRange(start: Duration.zero, duration: dur);
    } else {
      seg.timeRange = TimeRange(start: seg.timeRange.start, duration: dur);
    }
    if (!mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.dispose();
      });
      return;
    }
    setState(() {});
    ProjectHolder.current = _project;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.dispose();
    });
  }

  /// Superpose les textes actifs à la position de la tête de lecture.
  /// Rectangle (coordonnées écran) occupé réellement par la vidéo dans l'aperçu.
  Rect? _videoGlobalRect() {
    final rb = _previewKey.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null || !rb.hasSize) return null;
    final origin = rb.localToGlobal(Offset.zero);
    var left = origin.dx, top = origin.dy;
    var w = rb.size.width, h = rb.size.height;
    final c = _videoController;
    if (c != null && c.value.isInitialized && c.value.aspectRatio > 0 && h > 0) {
      final containerAspect = w / h;
      final videoAspect = c.value.aspectRatio;
      if (containerAspect > videoAspect) {
        final vw = h * videoAspect;
        left += (w - vw) / 2;
        w = vw;
      } else if (containerAspect < videoAspect) {
        final vh = w / videoAspect;
        top += (h - vh) / 2;
        h = vh;
      }
    }
    return Rect.fromLTWH(left, top, w, h);
  }

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
          var y = ((p['y'] ?? 0.5) as num).toDouble();
          y = y.clamp(0.0, 1.0);
          final x = ((p['x'] ?? 0.5) as num).toDouble().clamp(0.0, 1.0).toDouble();
          final size = ((p['size'] ?? 56) as num).toDouble();
          final isSelected = !_textEditingMode && _selectedSegment?.id == seg.id;
          final textWidget = LayoutBuilder(builder: (context, c) {
            final scale = (MediaQuery.of(context).size.height * 0.3) / 720;
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: isSelected
                  ? BoxDecoration(
                      border: Border.all(color: Colors.white, width: 1.5),
                      borderRadius: BorderRadius.circular(4),
                    )
                  : null,
              child: Text(
                '${p['text'] ?? ''}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: size * scale * 2,
                  fontWeight: FontWeight.bold,
                  color: Color((p['color'] ?? 0xFFFFFFFF) as int),
                  shadows: const [Shadow(blurRadius: 4, color: Colors.black)],
                ),
              ),
            );
          });
          Widget textOverlay = LayoutBuilder(
            builder: (context, constraints) {
              final renderBox = _previewKey.currentContext?.findRenderObject() as RenderBox?;
              double top = 0;
              double height = constraints.maxHeight;
              double left = 0;
              double width = constraints.maxWidth;
              if (renderBox != null && renderBox.hasSize) {
                final videoRect = renderBox.localToGlobal(Offset.zero);
                final selfRect = (context.findRenderObject() as RenderBox?)?.localToGlobal(Offset.zero) ?? videoRect;
                top = videoRect.dy - selfRect.dy;
                left = videoRect.dx - selfRect.dx;
                height = renderBox.size.height;
                width = renderBox.size.width;
                final controller = _videoController;
                if (controller != null && controller.value.isInitialized && controller.value.aspectRatio > 0) {
                  final containerAspect = width / height;
                  final videoAspect = controller.value.aspectRatio;
                  if (containerAspect > videoAspect) {
                    final videoWidth = height * videoAspect;
                    left += (width - videoWidth) / 2;
                    width = videoWidth;
                  } else if (containerAspect < videoAspect) {
                    final videoHeight = width / videoAspect;
                    top += (height - videoHeight) / 2;
                    height = videoHeight;
                  }
                }
              }
              final yPos = top + y * height;
              return Stack(
                children: [
                  Positioned(
                    // Le centre du texte est placé en (x, y) : même repère que l'export.
                    left: left + x * width,
                    top: yPos,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: FractionalTranslation(
                        translation: const Offset(-0.5, -0.5),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            if (_textEditingMode) return;
                            setState(() {
                              _selectedSegment = seg;
                            });
                            ProjectHolder.current = _project;
                          },
                          onPanUpdate: (details) {
                            if (_textEditingMode) return;
                            final r = _videoGlobalRect();
                            final clip = seg.clip;
                            if (r == null || clip == null || r.width <= 0 || r.height <= 0) return;
                            final nx = ((details.globalPosition.dx - r.left) / r.width).clamp(0.0, 1.0);
                            final ny = ((details.globalPosition.dy - r.top) / r.height).clamp(0.0, 1.0);
                            clip.properties['x'] = nx;
                            clip.properties['y'] = ny;
                            if (!mounted) return;
                            setState(() => _selectedSegment = seg);
                            ProjectHolder.current = _project;
                          },
                          child: textWidget,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
          overlays.add(textOverlay);
        }
      }
    }
    if (_textEditingMode && _inlineTextController != null && _inlineTextFocusNode != null && _selectedSegment?.clip?.type == ClipType.text) {
      final seg = _selectedSegment!;
      final p = seg.clip?.properties ?? const {};
      var y = ((p['y'] ?? 0.5) as num).toDouble();
      y = y.clamp(0.0, 1.0);
      overlays.add(Align(
        alignment: Alignment(0, y * 2 - 1),
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 280),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.6),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.white, width: 1.5),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _inlineTextController,
                  focusNode: _inlineTextFocusNode,
                  autofocus: true,
                  maxLines: 2,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: 'Saisir du texte',
                    hintStyle: TextStyle(color: Colors.white54),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: _cancelInlineTextEdit,
                      child: const Text('Annuler', style: TextStyle(color: Colors.white70)),
                    ),
                    const SizedBox(width: 4),
                    FilledButton(
                      onPressed: _commitInlineTextEdit,
                      child: const Text('Valider'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ));
    }
    return Stack(fit: StackFit.expand, children: [base, ...overlays]);
  }

  // ───────────── Matrice couleur de l'aperçu (filtres) ─────────────

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

  /// Même ordre que l'export Media3 : saturation → sépia → contraste → luminosité.
  List<double> _filterMatrix(Clip c) {
    List<double> id() => [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1];
    final sv = 1 + c.saturation;
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final sat = id()..setAll(0, [
      lr * (1 - sv) + sv, lg * (1 - sv), lb * (1 - sv), 0, 0,
      lr * (1 - sv), lg * (1 - sv) + sv, lb * (1 - sv), 0, 0,
      lr * (1 - sv), lg * (1 - sv), lb * (1 - sv) + sv, 0, 0,
    ]);
    final a = c.sepia.clamp(0.0, 1.0).toDouble();
    final sep = id()..setAll(0, [
      1 - a + a * 0.393, a * 0.769, a * 0.189, 0, 0,
      a * 0.349, 1 - a + a * 0.686, a * 0.168, 0, 0,
      a * 0.272, a * 0.534, 1 - a + a * 0.131, 0, 0,
    ]);
    final k = 1 + c.contrast;
    final off = (0.5 - 0.5 * k) * 255;
    final con = id();
    con[0] = k; con[6] = k; con[12] = k;
    con[4] = off; con[9] = off; con[14] = off;
    final bri = id();
    bri[4] = c.brightness * 255; bri[9] = c.brightness * 255; bri[14] = c.brightness * 255;
    return _mul5(bri, _mul5(con, _mul5(sep, sat))).sublist(0, 20);
  }

  Widget _filteredVideo(VideoPlayerController controller) {
    final clip = _selectedSegment?.clip;
    if (clip == null || clip.type == ClipType.text || !clip.hasFilters) {
      return VideoPlayer(controller);
    }
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(_filterMatrix(clip)),
      child: VideoPlayer(controller),
    );
  }

  // ───────────────────────── Filtres ─────────────────────────

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
    if (_textEditingMode) {
      return const SizedBox.shrink();
    }

    final track = selected == null
        ? null
        : _project?.tracks.cast<Track?>().firstWhere(
          (t) => t!.segments.any((s) => s.id == selected.id),
      orElse: () => null,
    );

    final index = track == null
        ? -1
        : track.segments.indexWhere((s) => s.id == selected?.id);

    final isTextSelected = _isText(selected);
    if (isTextSelected && selected?.clip != null) {
      final textClip = selected!.clip!;
      final textProps = textClip.properties;
      return Container(
        color: Colors.black,
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.only(bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Désélectionner',
                    onPressed: () {
                      setState(() {
                        _selectedSegment = null;
                      });
                    },
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                  const Expanded(
                    child: Text(
                      'Texte',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _editText,
                      icon: const Icon(Icons.edit, size: 18),
                      label: const Text('Modifier'),
                    ),
                    const SizedBox(width: 8),
                    const Text('Taille', style: TextStyle(color: Colors.white70, fontSize: 12)),
                    SizedBox(
                      width: 140,
                      child: Slider(
                        min: 20,
                        max: 140,
                        value: ((textProps['size'] ?? 56) as num).toDouble().clamp(20, 140),
                        onChanged: (v) {
                          textProps['size'] = v.round();
                          ProjectHolder.current = _project;
                          if (mounted) setState(() {});
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text('Couleur', style: TextStyle(color: Colors.white70, fontSize: 12)),
                    ...[
                      0xFFFFFFFF,
                      0xFFFFEB3B,
                      0xFFFF5252,
                      0xFF40C4FF,
                      0xFF69F0AE,
                      0xFF000000,
                    ].map((c) => Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: GestureDetector(
                            onTap: () {
                              textProps['color'] = c;
                              ProjectHolder.current = _project;
                              if (mounted) setState(() {});
                            },
                            child: CircleAvatar(
                              radius: 14,
                              backgroundColor: Color(c),
                              child: ((textProps['color'] ?? 0xFFFFFFFF) as int) == c
                                  ? const Icon(Icons.check, size: 16, color: Colors.grey)
                                  : null,
                            ),
                          ),
                        )),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: 'Supprimer',
                      onPressed: () {
                        _deleteSelected();
                        setState(() {
                          _selectedSegment = null;
                        });
                      },
                      icon: const Icon(Icons.delete),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget tool({
      required IconData icon,
      required String label,
      required VoidCallback? onPressed,
      bool primary = false,
      bool danger = false,
    }) {
      final color = primary
          ? const Color(0xFFB8F64A)
          : danger
              ? const Color(0xFFFF6670)
              : Colors.white70;
      return SizedBox(
        width: 68,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 36,
                  decoration: BoxDecoration(
                    color: primary
                        ? const Color(0xFFB8F64A)
                        : const Color(0xFF25272D),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: primary
                          ? const Color(0xFFB8F64A)
                          : Colors.white.withOpacity(0.06),
                    ),
                  ),
                  child: Icon(
                    icon,
                    size: 19,
                    color: primary ? const Color(0xFF11130B) : color,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: onPressed == null ? Colors.white24 : color,
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      color: const Color(0xFF111216),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            tool(
              icon: Icons.video_library_outlined,
              label: 'Importer',
              onPressed: _importVideo,
              primary: true,
            ),
            tool(
              icon: Icons.add_box_outlined,
              label: 'Clip vide',
              onPressed: _addEmptySegment,
            ),
            tool(
              icon: Icons.title_rounded,
              label: 'Texte',
              onPressed: _addText,
            ),
            if (selected != null && !isTextSelected && selected.clip != null)
              tool(
                icon: Icons.speed_rounded,
                label: 'Vitesse',
                onPressed: _editSpeedVolume,
              ),
            if (selected != null && !isTextSelected && selected.clip != null)
              tool(
                icon: Icons.auto_awesome_outlined,
                label: 'Filtres',
                onPressed: _editFilters,
              ),
            if (selected != null)
              tool(
                icon: Icons.delete_outline_rounded,
                label: 'Supprimer',
                onPressed: _deleteSelected,
                danger: true,
              ),
            if (selected != null && track != null)
              tool(
                icon: Icons.arrow_back_rounded,
                label: 'À gauche',
                onPressed: index > 0
                    ? () => _moveSegment(track, selected, -1)
                    : null,
              ),
            if (selected != null && track != null)
              tool(
                icon: Icons.arrow_forward_rounded,
                label: 'À droite',
                onPressed: index >= 0 && index < track.segments.length - 1
                    ? () => _moveSegment(track, selected, 1)
                    : null,
              ),
            if (selected != null && track != null)
              tool(
                icon: Icons.content_cut_rounded,
                label: 'Rogner',
                onPressed: selected.clip != null ? _trimSelected : null,
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final project = _project;
    final controller = _videoController;
    final timelineWidth = _timelineWidth();
    final selected = _selectedSegment;
    final isPlaying = controller?.value.isPlaying ?? false;

    return Scaffold(
      backgroundColor: const Color(0xFF08090B),
      appBar: AppBar(
        backgroundColor: const Color(0xFF111216),
        elevation: 0,
        leading: IconButton(
          tooltip: 'Retour',
          icon: const Icon(Icons.arrow_back_ios_new, size: 19),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Modifier le projet',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            Text(
              project?.name ?? 'Mon projet',
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Importer une vidéo',
            icon: const Icon(Icons.add_circle_outline, color: Color(0xFFB8F64A)),
            onPressed: _importVideo,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10, top: 9, bottom: 9),
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFB8F64A),
                foregroundColor: const Color(0xFF101108),
                padding: const EdgeInsets.symmetric(horizontal: 15),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () => Navigator.pushNamed(context, '/export'),
              child: const Text('Exporter', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 5,
            child: Container(
              width: double.infinity,
              color: const Color(0xFF08090B),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Row(
                      children: [
                        const Icon(Icons.circle, size: 7, color: Color(0xFFB8F64A)),
                        const SizedBox(width: 7),
                        const Text('APERÇU',
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.5,
                            )),
                        const Spacer(),
                        Text(
                          _formatTime(_playheadPosition),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 5),
                        child: AspectRatio(
                          aspectRatio: controller != null &&
                                  controller.value.isInitialized &&
                                  controller.value.aspectRatio > 0
                              ? controller.value.aspectRatio
                              : 9 / 16,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(5),
                            child: ColoredBox(
                              color: Colors.black,
                              child: _previewWithText(
                                controller != null && controller.value.isInitialized
                                    ? _filteredVideo(controller)
                                    : const Center(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.movie_outlined,
                                                color: Colors.white24, size: 42),
                                            SizedBox(height: 10),
                                            Text('Importez une vidéo pour commencer',
                                                style: TextStyle(
                                                    color: Colors.white38, fontSize: 12)),
                                          ],
                                        ),
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: 'Revenir au début du clip',
                          onPressed: selected == null
                              ? null
                              : () {
                                  setState(() {
                                    _playheadPosition = selected.timeRange.start;
                                  });
                                  final c = _videoController;
                                  if (c != null && c.value.isInitialized) {
                                    c.seekTo(selected.clip?.trimStart ?? Duration.zero);
                                  }
                                },
                          icon: const Icon(Icons.skip_previous_rounded, color: Colors.white70),
                        ),
                        const SizedBox(width: 12),
                        Material(
                          color: const Color(0xFFB8F64A),
                          shape: const CircleBorder(),
                          child: IconButton(
                            tooltip: isPlaying ? 'Pause' : 'Lire',
                            onPressed: () async {
                              final c = _videoController;
                              if (c == null || !c.value.isInitialized) {
                                if (selected != null) await _playSegment(selected);
                                return;
                              }
                              if (c.value.isPlaying) {
                                await c.pause();
                              } else {
                                await c.play();
                              }
                              if (mounted) setState(() {});
                            },
                            icon: Icon(
                              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                              color: const Color(0xFF11130B),
                              size: 30,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        IconButton(
                          tooltip: 'Arrêter',
                          onPressed: () async {
                            final c = _videoController;
                            if (c != null && c.value.isInitialized) {
                              await c.pause();
                              await c.seekTo(selected?.clip?.trimStart ?? Duration.zero);
                            }
                            if (mounted) setState(() {});
                          },
                          icon: const Icon(Icons.stop_rounded, color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(height: 1, color: const Color(0xFF292A2F)),
          Expanded(
            flex: 4,
            child: Container(
              color: const Color(0xFF111216),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 7),
                    child: Row(
                      children: [
                        const Text('Timeline',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF292B2F),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            '${project?.tracks.fold<int>(0, (n, t) => n + t.segments.length) ?? 0} clips',
                            style: const TextStyle(color: Colors.white60, fontSize: 10),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          _formatShort(project == null
                              ? Duration.zero
                              : project.tracks
                                  .where((t) => t.type == TrackType.video)
                                  .expand((t) => t.segments)
                                  .fold<Duration>(
                                    Duration.zero,
                                    (total, segment) => total + _segmentDuration(segment),
                                  )),
                          style: const TextStyle(color: Colors.white54, fontSize: 11),
                        ),
                        IconButton(
                          tooltip: 'Ajouter une vidéo',
                          visualDensity: VisualDensity.compact,
                          onPressed: _importVideo,
                          icon: const Icon(Icons.add, color: Color(0xFFB8F64A), size: 21),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: project == null
                        ? const SizedBox.shrink()
                        : SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: SizedBox(
                              width: timelineWidth.clamp(400.0, 1000000.0),
                              child: Column(
                                children: [
                                  _buildTimelineRuler(timelineWidth),
                                  Expanded(
                                    child: ListView.builder(
                                      itemCount: project.tracks.length,
                                      itemBuilder: (context, index) => _buildTrack(
                                        project.tracks[index],
                                        timelineWidth,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                  ),
                  _buildPlayheadControls(),
                  Container(height: 1, color: const Color(0xFF292A2F)),
                  SafeArea(
                    top: false,
                    minimum: const EdgeInsets.only(bottom: 4),
                    child: _buildActions(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
