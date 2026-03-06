import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const MpvGemApp());
}

class MpvGemApp extends StatelessWidget {
  const MpvGemApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData.dark(),
    home: const MpvGemHome(),
  );
}

class MpvGemHome extends StatefulWidget {
  const MpvGemHome({super.key});
  @override
  State<MpvGemHome> createState() => _MpvGemHomeState();
}

class _MpvGemHomeState extends State<MpvGemHome> {
  Process? _mpvProcess;
  double _fade = 1.0;
  int _speed = 50;
  String _statusMessage = '';

  static const String _mpvBin = '/opt/homebrew/bin/mpv';
  final String _selectedPath = '/Users/tilton/igor/linux/film';

  /// Generates a Lua script that applies a fade-to-black filter chain.
  Future<File> _createLuaScript() async {
    final tempDir = await getTemporaryDirectory();
    final luaFile = File(p.join(tempDir.path, 'gem_logic.lua'));

    final luaContent = '''
local mp = require 'mp'

mp.register_event("file-loaded", function()
    local duration = mp.get_property_number("duration", 0)
    mp.set_property_number("speed", $_speed / 100.0)
    local fade_dur = $_fade
    local st_out = math.max(0, duration - fade_dur)
    local vf = string.format(
        "format=yuv420p,fade=t=in:st=0:d=%.2f,fade=t=out:st=%.2f:d=%.2f",
        fade_dur, st_out, fade_dur)
    mp.commandv("vf", "set", vf)
end)
''';
    return await luaFile.writeAsString(luaContent);
  }

  List<String> _getMediaFiles(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) return [];
    return dir.listSync()
        .whereType<File>()
        .where((f) => ['.mp4', '.mov', '.mkv'].contains(p.extension(f.path).toLowerCase()))
        .map((f) => f.path)
        .toList();
  }

  Future<void> _launch() async {
    _mpvProcess?.kill();
    _mpvProcess = null;
    setState(() => _statusMessage = '');

    final luaScript = await _createLuaScript();
    final mainFiles = _getMediaFiles(_selectedPath);
    final gapFiles = _getMediaFiles(p.join(_selectedPath, 'gap'));
    final idleFiles = _getMediaFiles(p.join(_selectedPath, 'idle'));

    if (mainFiles.isEmpty) {
      setState(() => _statusMessage = 'No media files found in $_selectedPath');
      return;
    }

    mainFiles.shuffle();
    List<String> playlist = [];
    for (var f in mainFiles) {
      playlist.add(f);
      if (gapFiles.isNotEmpty) {
        final n = Random().nextInt(3) + 1;
        for (int i = 0; i < n; i++) {
          playlist.add((List.from(gapFiles)..shuffle()).first);
        }
      }
      if (idleFiles.isNotEmpty) {
        playlist.addAll(List.from(idleFiles)..shuffle());
      }
    }

    final args = [
      '--no-config',
      '--force-window=yes',
      '--no-audio',
      '--ontop',
      '--script=${luaScript.path}',
      '--loop-playlist=inf',
      ...playlist,
    ];

    try {
      _mpvProcess = await Process.start(_mpvBin, args);
    } catch (e) {
      if (mounted) setState(() => _statusMessage = 'Failed to launch mpv: $e');
      _mpvProcess = null;
      return;
    }

    _mpvProcess!.stdout.listen((data) => debugPrint(String.fromCharCodes(data)));

    final stderrBuffer = StringBuffer();
    _mpvProcess!.stderr.listen((data) {
      final text = String.fromCharCodes(data);
      debugPrint(text);
      stderrBuffer.write(text);
    });

    _mpvProcess!.exitCode.then((code) {
      if (code != 0 && mounted) {
        final errText = stderrBuffer.toString().trim();
        setState(() {
          _statusMessage = errText.isNotEmpty
              ? errText
              : 'mpv exited with code $code';
          _mpvProcess = null;
        });
      }
    });
  }

  @override
  void dispose() {
    _mpvProcess?.kill();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MPV Gem Engine')),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Target: $_selectedPath', style: const TextStyle(fontSize: 10)),
            const SizedBox(height: 20),
            Text('Speed: $_speed%'),
            Slider(value: _speed.toDouble(), min: 10, max: 200, onChanged: (v) => setState(() => _speed = v.round())),
            Text('Fade: ${_fade.toStringAsFixed(1)}s'),
            Slider(value: _fade, min: 0.0, max: 2.0, onChanged: (v) => setState(() => _fade = v)),
            const SizedBox(height: 20),
            Center(
              child: ElevatedButton(
                onPressed: _launch,
                style: ElevatedButton.styleFrom(minimumSize: const Size(200, 60)),
                child: const Text('RUN'),
              ),
            ),
            if (_statusMessage.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _statusMessage,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.redAccent,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}