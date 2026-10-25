import 'dart:io';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';
import 'package:file_picker/file_picker.dart';
import '../../models/capcut_models.dart';
import '../../services/segment_service.dart';
import '../../services/video_metadata_service.dart';
import '../../core/project_holder.dart';

/// Écran d'édition — architecture CapCut (REA : Project → Track → Segment → Clip,
/// SegmentService, ProjectServiceImpl, DraftTransformerKt, pont natif SWIG Draft).
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final _projectService = ProjectServiceImpl();
  final _metadataService = VideoMetadataService();
  final _uuid = const Uuid();

  Project? _project;
  VideoPlayerController? _videoController;
  Segment? _selectedSegment;

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

  // ── Import média (file_picker) ──
  Future<void> _importVideo() async {
    if (_project == null) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
    );
    if (result == null || result.files.single.path == null) return;
    final path = result.files.single.path!;
    final fileName = path.split('/').last.split('\\').last;

    // Lit la durée réelle via le pont natif (MediaMetadataRetriever)
    final metadata = await _metadataService.readMetadata(path);
    if (!mounted) return;
    if (metadata == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Durée réelle illisible : 5 s utilisées par défaut')));
    }
    final duration = metadata?.duration ?? const Duration(seconds: 5);

    // Crée un Clip (matériau CapCut) puis un Segment qui le référence
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

    final videoTrack = _project!.tracks.firstWhere(
      (t) => t.type == TrackType.video,
      orElse: () => _project!.tracks[0],
    );
    _projectService.addSegment(_project!, videoTrack.id, segment);
    _recomputeTimeline();
  }

  // ── Ajout d'un segment vide ──
  void _addEmptySegment() {
    if (_project == null) return;
    final track = _project!.tracks.firstWhere(
      (t) => t.type == TrackType.video,
      orElse: () => _project!.tracks.first,
    );
    final segment = Segment(
      id: _uuid.v4(),
      name: 'Clip',
      timeRange: TimeRange(
        start: Duration.zero,
        duration: const Duration(seconds: 5),
      ),
    );
    _projectService.addSegment(_project!, track.id, segment);
    _recomputeTimeline();
    ProjectHolder.current = _project;
    setState(() {});
  }

  // ── Découpe le segment sélectionné ──
  void _splitSelected(Duration at) {
    if (_project == null || _selectedSegment == null) return;
    final track = _project!.tracks.firstWhere(
      (t) => t.segments.any((s) => s.id == _selectedSegment!.id),
      orElse: () => _project!.tracks.first,
    );
    _projectService.splitSegmentAt(_project!, track.id, _selectedSegment!.id, at);
    _selectedSegment = null;
    _recomputeTimeline();
  }

  // ── Recalcule les positions séquentielles des clips vidéo ──
  void _recomputeTimeline() {
    if (_project == null) return;
    Track? videoTrack;
    try {
      videoTrack = _project!.tracks.firstWhere((t) => t.type == TrackType.video);
    } catch (_) {
      if (_project!.tracks.isNotEmpty) videoTrack = _project!.tracks[0];
    }
    if (videoTrack == null) return;
    Duration cursor = Duration.zero;
    // Sort by current timeRange.start to be safe
    videoTrack.segments.sort((a,b) => a.timeRange.start.compareTo(b.timeRange.start));
    for (final seg in videoTrack.segments) {
      final durEff = seg.clip?.effectiveDuration ?? seg.timeRange.duration;
      seg.timeRange = TimeRange(start: cursor, duration: durEff);
      cursor += durEff;
    }
    videoTrack.segments.sort((a,b) => a.timeRange.start.compareTo(b.timeRange.start));
    ProjectHolder.current = _project;
    setState(() {});
  }

  void _moveSelectedUp() {
    if (_project == null || _selectedSegment == null) return;
    final track = _project!.tracks.firstWhere(
      (t) => t.segments.any((s) => s.id == _selectedSegment!.id),
      orElse: () => _project!.tracks.first,
    );
    _moveSegment(track, _selectedSegment!, -1);
  }

  String _fmt(Duration d) {
    final s = d.inSeconds % 60;
    final m = d.inMinutes;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  void _moveSegment(Track track, Segment seg, int delta) {
    final idx = track.segments.indexWhere((s) => s.id == seg.id);
    if (idx < 0) return;
    final newIdx = idx + delta;
    if (newIdx < 0 || newIdx >= track.segments.length) return;
    final removed = track.segments.removeAt(idx);
    track.segments.insert(newIdx, removed);
    ProjectHolder.current = _project;
    _recomputeTimeline();
  }

  Future<void> _trimSelected() async {
    if (_selectedSegment == null || _selectedSegment!.clip == null) return;
    final clip = _selectedSegment!.clip!;
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rognage (ms)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Durée source: ${clip.duration.inMilliseconds} ms'),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'trimStart,trimEnd (ex: 500,1000)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
        ],
      ),
    );
    final text = controller.text;
    controller.dispose();
    if (ok != true) return;
    final parts = text.split(',');
    if (parts.length != 2) return;
    final ts = int.tryParse(parts[0].trim()) ?? 0;
    final te = int.tryParse(parts[1].trim()) ?? 0;
    final trimStart = Duration(milliseconds: ts.clamp(0, clip.duration.inMilliseconds));
    final trimEnd = Duration(milliseconds: te.clamp(0, clip.duration.inMilliseconds - trimStart.inMilliseconds));
    if (trimStart + trimEnd >= clip.duration) return;
    clip.trimStart = trimStart;
    clip.trimEnd = trimEnd;
    _recomputeTimeline();
  }
  void _playSegment(Segment segment) {
    final old = _videoController;
    _videoController = null;
    old?.dispose();
    final assetPath = segment.clip?.assetPath;
    if (assetPath != null) {
      _videoController = VideoPlayerController.file(File(assetPath))
        ..initialize().then((_) {
          if (mounted) setState(() {});
          _videoController?.play();
        });
    } else {
      _videoController = null;
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CapCut Editor'),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download, color: Colors.white),
            onPressed: () {
              Navigator.pushNamed(context, '/export');
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Prévisualisation (domaine 3 : prévisualisation) ──
          Expanded(
            flex: 3,
            child: Container(
              color: Colors.black,
              child: _videoController != null &&
                      _videoController!.value.isInitialized
                  ? Center(
                      child: AspectRatio(
                        aspectRatio: _videoController!.value.aspectRatio,
                        child: VideoPlayer(_videoController!),
                      ),
                    )
                  : const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.play_circle_outline,
                              size: 64, color: Colors.white24),
                          SizedBox(height: 12),
                          Text('Sélectionnez un clip pour prévisualiser',
                              style: TextStyle(color: Colors.grey, fontSize: 14)),
                        ],
                      ),
                    ),
            ),
          ),
          const Divider(height: 1, color: Colors.grey),

          // ── Timeline multitrack (domaine 1 : projet et timeline) ──
          Expanded(
            flex: 2,
            child: _project == null
                ? const SizedBox()
                : StreamBuilder<Object?>(
                    stream: const Stream<Object?>.empty(),
                    builder: (context, snapshot) {
                      return Column(
                        children: [
                          // Règle temporelle
                          Container(
                            height: 28,
                            color: Colors.grey[850],
                            padding: const EdgeInsets.only(left: 80),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: List.generate(
                                (_project!.duration.inSeconds + 2).ceil(),
                                (i) => Container(
                                  width: 60,
                                  height: double.infinity,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    '${i}s',
                                    style: const TextStyle(
                                        color: Colors.grey, fontSize: 10),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // Pistes
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              physics: const AlwaysScrollableScrollPhysics(),
                              child: SizedBox(
                                width: 80 + ((_project!.duration.inMilliseconds / 1000 * 60) + 200).clamp(400, double.infinity),
                                child: ListView.builder(
                                  physics: const NeverScrollableScrollPhysics(),
                                  shrinkWrap: true,
                                  itemCount: _project!.tracks.length,
                                  itemBuilder: (context, ti) {
                                    final track = _project!.tracks[ti];
                                    return Container(
                                      height: 64,
                                      color: track.type == TrackType.video
                                          ? Colors.grey[900]
                                          : Colors.grey[850],
                                      child: Stack(
                                        children: [
                                          // Label piste
                                          Positioned(
                                            left: 0,
                                            top: 0,
                                            bottom: 0,
                                            child: Container(
                                              width: 80,
                                              color: Colors.grey[800],
                                              child: Center(
                                                child: Text(
                                                  track.name,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 10,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
  ...track.segments.asMap().entries.map((e) {
    final idx = e.key;
    final seg = e.value;
    final selected = _selectedSegment?.id == seg.id;
    return Positioned(
      key: ValueKey('seg_${seg.id}'),
      left: 80 + seg.timeRange.start.inMilliseconds / 1000 * 60,
      top: 8,
      bottom: 8,
      child: DragTarget<Segment>(
        onWillAccept: (data) => data != null && data.id != seg.id,
        onAccept: (data) {
          final tidx = track.segments.indexWhere((s) => s.id == data.id);
          if (tidx < 0) return;
          if (tidx == idx) return;
          final removed = track.segments.removeAt(tidx);
          track.segments.insert(idx, removed);
          ProjectHolder.current = _project;
          _recomputeTimeline();
        },
        builder: (context, candidate, rejected) {
          return GestureDetector(
            onTap: () { setState(() { _selectedSegment = seg; }); _playSegment(seg); },
            child: LongPressDraggable<Segment>(
              data: seg,
              dragAnchorStrategy: pointerDragAnchorStrategy,
              feedback: Material(
                color: Colors.transparent,
                child: Container(
                  width: ((seg.clip?.effectiveDuration ??
    seg.timeRange.duration).inMilliseconds / 1000 * 60)
    .clamp(1.0, double.infinity),
                  height: 48,
                  decoration: BoxDecoration(color: Colors.blueAccent, borderRadius: BorderRadius.circular(4)),
                  child: Center(child: Text(seg.name, style: const TextStyle(color: Colors.white, fontSize: 9))),
                ),
              ),
              childWhenDragging: Container(width: ((seg.clip?.effectiveDuration ?? seg.timeRange.duration).inMilliseconds / 1000 * 60).clamp(40.0, double.infinity).toDouble()),
              child: Container(
                width: ((seg.clip?.effectiveDuration ?? seg.timeRange.duration).inMilliseconds / 1000 * 60).clamp(40.0, double.infinity).toDouble(),
                decoration: BoxDecoration(
                  color: candidate.isNotEmpty ? Colors.amber : (selected ? Colors.blueAccent : (track.type == TrackType.video ? Colors.blue : Colors.green)),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.white.withOpacity(0.3)),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(seg.name, style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
                    Text(_fmt(seg.clip?.effectiveDuration ?? seg.timeRange.duration), style: const TextStyle(color: Colors.white70, fontSize: 7)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          // Barre d'actions (domaine 2 : opérations de montage)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              ElevatedButton.icon(
                                onPressed: _importVideo,
                                icon: const Icon(Icons.add_a_photo, size: 18),
                                label: const Text('Import Vidéo'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.blue,
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton.icon(
                                onPressed: _addEmptySegment,
                                icon: const Icon(Icons.add, size: 18),
                                label: const Text('Ajouter Clip'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                ),
                              ),
                              const SizedBox(width: 8),
                              if (_selectedSegment != null) ...[
                                const SizedBox(width: 8),
                                ElevatedButton.icon(
                                  onPressed: () {
                                    if (_project == null || _selectedSegment == null) return;
                                    final track = _project!.tracks.firstWhere((t) => t.segments.any((s) => s.id == _selectedSegment!.id), orElse: () => _project!.tracks.first);
                                    _moveSegment(track, _selectedSegment!, -1);
                                  },
                                  icon: const Icon(Icons.arrow_upward, size: 18),
                                  label: const Text('Monter'),
                                ),
                                const SizedBox(width: 8),
                                ElevatedButton.icon(
                                  onPressed: () {
                                    if (_project == null || _selectedSegment == null) return;
                                    final track = _project!.tracks.firstWhere((t) => t.segments.any((s) => s.id == _selectedSegment!.id), orElse: () => _project!.tracks.first);
                                    _moveSegment(track, _selectedSegment!, 1);
                                  },
                                  icon: const Icon(Icons.arrow_downward, size: 18),
                                  label: const Text('Descendre'),
                                ),
                                const SizedBox(width: 8),
                                ElevatedButton.icon(
                                  onPressed: _trimSelected,
                                  icon: const Icon(Icons.content_cut, size: 18),
                                  label: const Text('Rogner'),
                                ),
                              ],
                            ],
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
