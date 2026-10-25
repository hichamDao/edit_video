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

      // Le fichier source est lu en entier : on arrête la lecture à la fin du
      // clip (rognage inclus) et on synchronise la tête de lecture.
      final sourceEnd = clip.trimStart + segment.timeRange.duration;
      controller.addListener(() {
        if (!mounted || !identical(_videoController, controller)) return;
        final value = controller.value;
        if (!value.isPlaying) return;
        var local = value.position - clip.trimStart;
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
            child: Container(
              width: double.infinity,
              color: Colors.black,
              child: controller != null && controller.value.isInitialized
                  ? Center(
                child: AspectRatio(
                  aspectRatio: controller.value.aspectRatio,
                  child: VideoPlayer(controller),
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
            ),
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