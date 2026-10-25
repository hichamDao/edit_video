import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../services/export_service.dart';
import '../../core/project_holder.dart';

/// Écran d'export — envoie la composition au pont natif Media3 (Android).
/// Les paramètres d'export (résolution, bitrate, fps, codec) sont négociés par Media3.
class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key});

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  final _exportService = ExportService();

  int _width = 1920;
  int _height = 1080;
  int _fps = 30;
  int _bitrate = 8000000;
  bool _includeAudio = true;

  @override
  void dispose() {
    super.dispose();
  }

  Future<String> _getOutputPath() async {
    final dir = await getTemporaryDirectory();
    return '${dir.path}/export_${DateTime.now().millisecondsSinceEpoch}.mp4';
  }

  void _showMessage(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final project = ProjectHolder.current;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Export Vidéo'),
        backgroundColor: Colors.red,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (project == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8.0),
                child: Text(
                  'Aucun projet a exporter. Retournez a l\'editeur et importez des clips.',
                  style: TextStyle(color: Colors.orange, fontSize: 14),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Text(
                  'Projet : ${project.name} — ${project.duration.inSeconds}s',
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ),
            const SizedBox(height: 8),
            const Text('Resolution',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            DropdownButton<int>(
              value: _width,
              items: const [
                DropdownMenuItem(value: 1280, child: Text('720p (1280x720)')),
                DropdownMenuItem(value: 1920, child: Text('1080p (1920x1080)')),
                DropdownMenuItem(value: 3840, child: Text('4K (3840x2160)')),
              ],
              onChanged: (v) => setState(() {
                _width = v!;
                _height = (_width * 9 / 16).round();
              }),
            ),
            const SizedBox(height: 16),
            const Text('FPS',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            DropdownButton<int>(
              value: _fps,
              items: const [
                DropdownMenuItem(value: 24, child: Text('24 fps')),
                DropdownMenuItem(value: 30, child: Text('30 fps')),
                DropdownMenuItem(value: 60, child: Text('60 fps')),
              ],
              onChanged: (v) => setState(() => _fps = v!),
            ),
            const SizedBox(height: 16),
            const Text('Bitrate (bps)',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Slider(
              value: _bitrate.toDouble(),
              min: 1000000,
              max: 20000000,
              divisions: 8,
              label: '${(_bitrate / 1000000).toStringAsFixed(1)} Mbps',
              onChanged: (v) => setState(() => _bitrate = v.toInt()),
            ),
            const SizedBox(height: 16),
            CheckboxListTile(
              title: const Text('Inclure l\'audio'),
              value: _includeAudio,
              onChanged: (v) => setState(() => _includeAudio = v!),
            ),
            const SizedBox(height: 24),
            StreamBuilder<ExportProgress>(
              stream: _exportService.stream,
              builder: (context, snap) {
                final p = snap.data;
                return Column(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _exportService.status == ExportStatus.processing
                            ? null
                            : () async {
                                if (project == null) {
                                  _showMessage('Aucun projet a exporter');
                                  return;
                                }
                                final cfg = ExportVideoConfig()
                                  ..width = _width
                                  ..height = _height
                                  ..bitrate = _bitrate
                                  ..fps = _fps
                                  ..includeAudio = _includeAudio;

                                final outputPath = await _getOutputPath();
                                await _exportService.exportProject(
                                  project: project,
                                  outputPath: outputPath,
                                  config: cfg,
                                );
                                setState(() {});
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: Text(
                          _exportService.status == ExportStatus.processing
                              ? 'Export... ${(_exportService.progress * 100).toInt()}%'
                              : 'Exporter la video',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 16),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (p != null && p.status == ExportStatus.processing)
                      Column(
                        children: [
                          LinearProgressIndicator(value: p.progress),
                          const SizedBox(height: 8),
                          Text(
                            '${(p.progress * 100).toInt()}% - ${p.message ?? ''}',
                          ),
                        ],
                      ),
                    if (_exportService.status == ExportStatus.completed &&
                        _exportService.outputPath != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: Text(
                          'Export termine : ${_exportService.outputPath}',
                          style: const TextStyle(
                              color: Colors.green, fontSize: 14),
                        ),
                      ),
                    if (_exportService.status == ExportStatus.failed)
                      Text('Echec: ${_exportService.message}',
                          style: TextStyle(color: Colors.red, fontSize: 16)),
                    if (_exportService.status == ExportStatus.unsupported)
                      const Text(
                        'Export natif non disponible sur cette plateforme',
                        style: TextStyle(color: Colors.orange, fontSize: 14),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}