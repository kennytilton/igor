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
  double _fade = 0.4;
  int _speed = 50;
  final String _rootPath = '/Users/tilton/igor/linux/film';

  // Creates the Lua script that handles logging and fades
  Future<File> _createLuaScript() async {
    final tempDir = await getTemporaryDirectory();
    // Add this line to ensure the path exists
    if (!tempDir.existsSync()) {
      tempDir.createSync(recursive: true);
    }

    final luaFile = File(p.join(tempDir.path, 'gem_logic.lua'));
    final luaContent = '''
local mp = require 'mp'
local last_cat = ""

mp.register_event("file-loaded", function()
    local path = mp.get_property("path", ""):lower()
    local duration = mp.get_property_number("duration", 0)
    local cat = "MAIN"
    
    if path:find("/gap/") then cat = "GAP"
    elseif path:find("/idle/") then cat = "IDLE"
    end

    if cat ~= last_cat then
        print("\\n>>> STARTING " .. cat)
        last_cat = cat
    end

    mp.set_property_number("speed", $_speed / 100.0)

    local st_out = math.max(0, duration - $_fade)
    local vf = string.format("format=yuv420p,fade=t=in:st=0:d=$_fade,fade=t=out:st=%.2f:d=$_fade", st_out)
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
    debugPrint('--- Launching MPV ---');
    _mpvProcess?.kill();

    final luaScript = await _createLuaScript();
    final mainFiles = _getMediaFiles(_rootPath);
    final gapFiles = _getMediaFiles(p.join(_rootPath, 'gap'));
    final idleFiles = _getMediaFiles(p.join(_rootPath, 'idle'));

    if (mainFiles.isEmpty) {
      debugPrint('Error: No files found in $_rootPath');
      return;
    }

    List<String> playlist = [];
    // ... (Your existing shuffle logic remains the same) ...
    mainFiles.shuffle();
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

    // UPDATE: Use the absolute path to mpv and catch errors
    try {
      _mpvProcess = await Process.start('/opt/homebrew/bin/mpv', [ // or /usr/local/bin/mpv
        '--no-config',
        '--force-window=yes',
        '--no-audio',
        '--ontop',
        '--script=${luaScript.path}',
        '--loop-playlist=inf',
        ...playlist,
      ]);

      // Listen to the process output
      _mpvProcess!.stdout.listen((data) => debugPrint('MPV STDOUT: ${String.fromCharCodes(data)}'));
      _mpvProcess!.stderr.listen((data) => debugPrint('MPV STDERR: ${String.fromCharCodes(data)}'));

      _mpvProcess!.exitCode.then((code) => debugPrint('MPV exited with code: $code'));

    } catch (e) {
      debugPrint('CRITICAL ERROR launching MPV: $e');
    }
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
          children: [
            Text('Speed: \$_speed%'),
            Slider(value: _speed.toDouble(), min: 10, max: 200, onChanged: (v) => setState(() => _speed = v.round())),
            Text('Fade: \${_fade.toStringAsFixed(1)}s'),
            Slider(value: _fade, min: 0.0, max: 2.0, onChanged: (v) => setState(() => _fade = v)),
            const SizedBox(height: 20),
            ElevatedButton(onPressed: _launch, child: const Text('RUN')),
          ],
        ),
      ),
    );
  }
}