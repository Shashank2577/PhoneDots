import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';

import '../../app_services.dart';
import '../../core/util/files.dart';
import '../../core/util/format.dart';
import '../../skills/skill.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';

/// Pickers that turn the outside world into [Attachment]s stored in app space.
class Attach {
  static Future<Attachment?> image(AppServices s, String id, {bool camera = false}) async {
    final x = await ImagePicker().pickImage(source: camera ? ImageSource.camera : ImageSource.gallery, maxWidth: 2048);
    if (x == null) return null;
    final path = await importFile(s.store.filesDir, x.path, x.name);
    return Attachment(id: id, kind: 'image', path: path, name: x.name);
  }

  static Future<Attachment?> file(AppServices s, String id, {required String kind}) async {
    final f = await FilePicker.pickFile(
      type: kind == 'audio' ? FileType.audio : FileType.custom,
      allowedExtensions: kind == 'audio' ? null : ['txt', 'md', 'csv', 'json', 'srt', 'html'],
    );
    if (f == null) return null;
    final source = kIsWeb ? f.name : f.path;
    if (source == null) return null;
    final path = await importFile(s.store.filesDir, source, f.name);
    return Attachment(id: id, kind: kind, path: path, name: f.name);
  }

  static Future<Attachment?> record(BuildContext context, AppServices s, String id) async {
    final path = await showModalBottomSheet<String>(
      context: context,
      isDismissible: false,
      builder: (_) => RecorderSheet(dir: s.store.filesDir),
    );
    if (path == null) return null;
    return Attachment(id: id, kind: 'audio', path: path, name: path.split('/').last);
  }

  static Future<Attachment?> chooseAndPick(BuildContext context, AppServices s, String id) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (key, icon, label) in [
              ('camera', Icons.photo_camera_outlined, 'Camera'),
              ('photo', Icons.image_outlined, 'Photo'),
              ('record', Icons.mic_none_rounded, 'Record audio'),
              ('audio', Icons.graphic_eq_rounded, 'Audio file'),
              ('document', Icons.description_outlined, 'Text document'),
            ])
              ListTile(leading: Icon(icon), title: Text(label), onTap: () => Navigator.pop(c, key)),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return null;
    try {
      if (choice == 'record') return await record(context, s, id);
      return switch (choice) {
        'camera' => await image(s, id, camera: true),
        'photo' => await image(s, id),
        'audio' => await file(s, id, kind: 'audio'),
        _ => await file(s, id, kind: 'document'),
      };
    } catch (e) {
      if (context.mounted) toast(context, 'Could not attach: $e');
      return null;
    }
  }
}

/// Records 16 kHz mono WAV, the format Voz, Who and Gemma audio prefer.
class RecorderSheet extends StatefulWidget {
  const RecorderSheet({super.key, required this.dir});
  final String? dir;

  @override
  State<RecorderSheet> createState() => _RecorderSheetState();
}

class _RecorderSheetState extends State<RecorderSheet> {
  final _rec = AudioRecorder();
  Timer? _timer;
  int _seconds = 0;
  bool _recording = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      if (!await _rec.hasPermission()) {
        setState(() => _error = 'Microphone permission is needed to record.');
        return;
      }
      final path = '${widget.dir ?? ''}/rec-${DateTime.now().millisecondsSinceEpoch}.wav';
      await _rec.start(const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1), path: path);
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() => _seconds++));
      setState(() => _recording = true);
    } catch (e) {
      setState(() => _error = 'Recording is not available here: $e');
    }
  }

  Future<void> _finish(bool keep) async {
    _timer?.cancel();
    final path = _recording ? await _rec.stop() : null;
    if (mounted) Navigator.pop(context, keep ? path : null);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _rec.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null)
              Text(_error!, style: context.text.bodyMedium, textAlign: TextAlign.center)
            else ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Dot(color: _recording ? p.danger : p.faint, size: 10),
                  const SizedBox(width: 10),
                  Text(
                    formatDuration(_seconds.toDouble()),
                    style: context.text.displaySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text('Recording on device. Nothing is uploaded.', style: context.text.bodySmall),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(onPressed: () => _finish(false), child: const Text('Cancel')),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(onPressed: _recording ? () => _finish(true) : null, child: const Text('Done')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
