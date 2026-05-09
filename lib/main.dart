import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const GoveeApp());
}

// ── Protocol constants ────────────────────────────────────────────────────────

const _multicastIp   = '239.255.255.250';
const _discoveryPort = 4001;
const _listenPort    = 4002;
const _controlPort   = 4003;

const _leftMask  = 0x01F;
const _rightMask = 0x3E0;

// ── Models ───────────────────────────────────────────────────────────────────

class SessionPack {
  final String name;
  final List<SessionScene> arc;
  final Map<String, AudioAsset> audioManifest;
  final String directoryPath;

  SessionPack({required this.name, required this.arc, required this.audioManifest, required this.directoryPath});

  factory SessionPack.fromJson(Map<String, dynamic> json, String dirPath) {
    return SessionPack(
      name: json['name'],
      directoryPath: dirPath,
      arc: (json['arc'] as List).map((s) => SessionScene.fromJson(s)).toList(),
      audioManifest: (json['audio_manifest'] as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, AudioAsset.fromJson(v))
      ),
    );
  }
}

class SessionScene {
  final String id, name;
  final String goveeRef;
  final String? ambientId;
  final int ambientVolume;
  final SpotifyConfig spotify;
  final List<Trigger> triggers;

  SessionScene({
    required this.id, required this.name, required this.goveeRef,
    this.ambientId, required this.ambientVolume, required this.spotify, required this.triggers
  });

  factory SessionScene.fromJson(Map<String, dynamic> json) {
    return SessionScene(
      id: json['id'],
      name: json['name'],
      goveeRef: json['govee_effect']['ref'],
      ambientId: json['ambient'],
      ambientVolume: json['ambient_volume'] ?? 0,
      spotify: json['spotify'] != null
          ? SpotifyConfig.fromJson(json['spotify'])
          : SpotifyConfig(uri: '', volume: 50),
      triggers: (json['triggers'] as List).map((t) => Trigger.fromJson(t)).toList(),
    );
  }
}

class SpotifyConfig {
  final String uri;
  final int volume;
  SpotifyConfig({required this.uri, required this.volume});
  factory SpotifyConfig.fromJson(Map<String, dynamic> json) =>
      SpotifyConfig(uri: json['uri'] ?? '', volume: json['volume'] ?? 50);
}

class Trigger {
  final String id, name, soundId;
  final String? flashRef;
  Trigger({required this.id, required this.name, required this.soundId, this.flashRef});
  factory Trigger.fromJson(Map<String, dynamic> json) => Trigger(
    id: json['id'],
    name: json['name'],
    soundId: json['sound'],
    flashRef: json['govee_flash']?['ref'],
  );
}

class AudioAsset {
  final String file;
  final int durationMs;
  AudioAsset({required this.file, required this.durationMs});
  factory AudioAsset.fromJson(Map<String, dynamic> json) =>
      AudioAsset(file: json['file'], durationMs: json['duration_ms']);
}

// ── Audio Engine ──────────────────────────────────────────────────────────────

class AudioEngine {
  final AudioPlayer _ambientPlayer = AudioPlayer();
  final List<AudioPlayer> _triggerPlayers = List.generate(6, (_) => AudioPlayer());
  int _triggerIndex = 0;

  AudioEngine() {
    _ambientPlayer.setReleaseMode(ReleaseMode.loop);
  }

  Future<void> playAmbient(String path, double volume) async {
    await _ambientPlayer.stop();
    await _ambientPlayer.setVolume(volume);
    await _ambientPlayer.play(DeviceFileSource(path));
  }

  Future<void> setAmbientVolume(double volume) async {
    await _ambientPlayer.setVolume(volume);
  }

  Future<void> playTrigger(String path) async {
    final player = _triggerPlayers[_triggerIndex];
    _triggerIndex = (_triggerIndex + 1) % _triggerPlayers.length;
    await player.stop();
    await player.play(DeviceFileSource(path));
  }

  Future<void> stopAll() async {
    await _ambientPlayer.stop();
    for (var p in _triggerPlayers) {
      await p.stop();
    }
  }

  void dispose() {
    _ambientPlayer.dispose();
    for (var p in _triggerPlayers) {
      p.dispose();
    }
  }
}

// ── UDP engine ────────────────────────────────────────────────────────────────

const _wifiChannel = MethodChannel('com.feru.govee_scene/wifi');

class GoveeEngine {
  InternetAddress? _deviceIp;
  RawDatagramSocket? _socket;

  Future<bool> discover() async {
    try {
      final hotspotIp = await _wifiChannel.invokeMethod<String>('getHotspotIp');
      if (hotspotIp != null) return _hotspotScan(hotspotIp);
    } catch (_) {}
    return _multicastDiscover();
  }

  Future<bool> _multicastDiscover() async {
    RawDatagramSocket? recv;
    RawDatagramSocket? send;
    try {
      try { await _wifiChannel.invokeMethod('acquireMulticastLock'); } catch (_) {}
      recv = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _listenPort);
      send = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final msg = jsonEncode({'msg': {'cmd': 'scan', 'data': {'account_topic': 'reserve'}}});
      send.send(utf8.encode(msg), InternetAddress(_multicastIp), _discoveryPort);
      final completer = Completer<bool>();
      Timer(const Duration(seconds: 2), () {
        if (!completer.isCompleted) {
          recv?.close(); send?.close();
          completer.complete(false);
        }
      });
      recv.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = recv?.receive();
          if (dg != null && !completer.isCompleted) {
            _deviceIp = dg.address;
            _initSocket().then((_) {
              recv?.close(); send?.close();
              completer.complete(true);
            });
          }
        }
      });
      final result = await completer.future;
      try { await _wifiChannel.invokeMethod('releaseMulticastLock'); } catch (_) {}
      return result;
    } catch (_) {
      recv?.close(); send?.close();
      return false;
    }
  }

  Future<bool> _hotspotScan(String hotspotIp) async {
    final parts = hotspotIp.split('.');
    if (parts.length != 4) return false;
    final prefix = '${parts[0]}.${parts[1]}.${parts[2]}.';
    RawDatagramSocket? recv;
    RawDatagramSocket? send;
    try {
      recv = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _listenPort);
      send = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final msg = utf8.encode(jsonEncode({'msg': {'cmd': 'scan', 'data': {'account_topic': 'reserve'}}}));
      for (var i = 2; i <= 254; i++) {
        send.send(msg, InternetAddress('$prefix$i'), _discoveryPort);
      }
      final completer = Completer<bool>();
      Timer(const Duration(seconds: 2), () {
        if (!completer.isCompleted) {
          recv?.close(); send?.close();
          completer.complete(false);
        }
      });
      recv.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = recv?.receive();
          if (dg != null && !completer.isCompleted) {
            _deviceIp = dg.address;
            _initSocket().then((_) {
              recv?.close(); send?.close();
              completer.complete(true);
            });
          }
        }
      });
      return await completer.future;
    } catch (_) {
      recv?.close(); send?.close();
      return false;
    }
  }

  Future<void> _initSocket() async {
    _socket?.close();
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  }

  void _send(Map<String, dynamic> cmd) {
    if (_deviceIp == null || _socket == null) return;
    final payload = utf8.encode(jsonEncode({'msg': cmd}));
    _socket!.send(payload, _deviceIp!, _controlPort);
  }

  void turnOn()                   => _send({'cmd': 'turn',       'data': {'value': 1}});
  void turnOff()                  => _send({'cmd': 'turn',       'data': {'value': 0}});
  void brightness(int v)          => _send({'cmd': 'brightness', 'data': {'value': v.clamp(1, 100)}});
  void color(int r, int g, int b) => _send({'cmd': 'colorwc',   'data': {'color': {'r': r, 'g': g, 'b': b}, 'colorTemInKelvin': 0}});

  void segColors(List<(int, int, int, int)> groups) {
    final commands = [for (final (r, g, b, mask) in groups) _segPacket(r, g, b, mask)];
    _send({'cmd': 'ptReal', 'data': {'command': commands}});
  }

  String _segPacket(int r, int g, int b, int mask) {
    final pkt = Uint8List(20);
    pkt[0] = 0x33; pkt[1] = 0x05; pkt[2] = 0x15; pkt[3] = 0x01;
    pkt[4] = r; pkt[5] = g; pkt[6] = b;
    var m = mask;
    for (var i = 0; i < 7; i++) {
      pkt[12 + i] = m & 0xFF;
      m >>= 8;
    }
    var xor = 0;
    for (var i = 0; i < 19; i++) xor ^= pkt[i];
    pkt[19] = xor;
    return base64Encode(pkt);
  }

  void dispose() => _socket?.close();
}

// ── Scene runner ──────────────────────────────────────────────────────────────

class SceneRunner {
  final GoveeEngine engine;
  Timer? _timer;
  bool _cancelled = false;
  int _sessionId = 0;
  final _rng = Random();

  SceneRunner(this.engine);

  void _stopLoop() {
    _cancelled = true;
    _sessionId++;
    _timer?.cancel();
    _timer = null;
  }

  void stop() {
    _stopLoop();
    engine.turnOff();
  }

  void _loop(Duration interval, void Function() fn) {
    _stopLoop();
    _cancelled = false;
    fn();
    _timer = Timer.periodic(interval, (_) => fn());
  }

  void police() {
    engine.turnOn(); engine.brightness(100);
    var phase = false;
    _loop(const Duration(milliseconds: 250), () {
      phase ? engine.segColors([(0, 40, 255, _leftMask), (255, 0, 0, _rightMask)])
            : engine.segColors([(255, 0, 0, _leftMask), (0, 40, 255, _rightMask)]);
      phase = !phase;
    });
  }

  void alarm() {
    engine.turnOn(); engine.brightness(100);
    var phase = false;
    _loop(const Duration(milliseconds: 250), () {
      phase ? engine.segColors([(10, 2, 0, _leftMask),  (255, 55, 0, _rightMask)])
            : engine.segColors([(255, 55, 0, _leftMask), (10, 2, 0, _rightMask)]);
      phase = !phase;
    });
  }

  void flicker() {
    _stopLoop(); _cancelled = false;
    final session = _sessionId;
    engine.turnOn();
    Future<void> barLoop(int mask) async {
      while (!_cancelled && _sessionId == session) {
        try {
          engine.segColors([(240, 230, 200, mask)]);
          await Future.delayed(Duration(milliseconds: 3000 + _rng.nextInt(2001)));
          if (_cancelled || _sessionId != session) break;
          var remaining = 500 + _rng.nextInt(1501);
          while (remaining > 0 && !_cancelled && _sessionId == session) {
            final cut = min(remaining, 80 + _rng.nextInt(421));
            engine.segColors([(2, 2, 2, mask)]);
            await Future.delayed(Duration(milliseconds: cut));
            remaining -= cut;
            if (_cancelled || _sessionId != session || remaining <= 0) break;
            engine.segColors([(240, 230, 200, mask)]);
            await Future.delayed(Duration(milliseconds: 40 + _rng.nextInt(81)));
          }
          if (!_cancelled && _sessionId == session) engine.segColors([(240, 230, 200, mask)]);
        } catch (_) {}
      }
    }
    barLoop(_leftMask); barLoop(_rightMask);
  }

  void club() {
    engine.turnOn(); engine.brightness(100);
    const pink = (255, 0, 180), green = (0, 255, 80);
    final t0 = DateTime.now().millisecondsSinceEpoch;
    _loop(const Duration(milliseconds: 150), () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final lColor = _rng.nextBool() ? pink : green;
      final rColor = lColor == pink ? green : pink;
      final v = (sin(2 * pi * 2.0 * (now - t0) / 1000.0) + 1) / 2;
      final scale = 0.55 + 0.45 * v;
      engine.segColors([
        ((lColor.$1 * scale).round(), (lColor.$2 * scale).round(), (lColor.$3 * scale).round(), _leftMask),
        ((rColor.$1 * scale).round(), (rColor.$2 * scale).round(), (rColor.$3 * scale).round(), _rightMask),
      ]);
    });
  }

  void disian() {
    engine.turnOn();
    var phase = 0.0;
    _loop(const Duration(milliseconds: 50), () {
      phase += 0.04;
      final v = (sin(phase) + 1) / 2;
      if (_rng.nextDouble() < 0.015) {
        engine.color(200, 210, 255); engine.brightness(85);
        return;
      }
      engine.color((65 + v * 45).round(), 0, (105 + v * 95).round());
      engine.brightness((22 + v * 58).round());
    });
  }

  void flash(String? ref) {
    if (ref == 'white-burst') {
      engine.turnOn(); engine.brightness(100); engine.color(255, 255, 255);
      Timer(const Duration(milliseconds: 200), () => engine.brightness(0));
    } else if (ref == 'orange-burst') {
      engine.turnOn(); engine.brightness(100); engine.color(255, 100, 0);
      Timer(const Duration(milliseconds: 200), () => engine.brightness(0));
    } else if (ref == 'purple-pulse') {
      engine.turnOn(); engine.brightness(100); engine.color(180, 0, 255);
      Timer(const Duration(milliseconds: 300), () => engine.brightness(20));
    }
  }

  void setByRef(String ref) {
    switch (ref) {
      case 'police':  police();  break;
      case 'alarm':   alarm();   break;
      case 'club':    club();    break;
      case 'flicker': flicker(); break;
      case 'disian':  disian();  break;
      case 'off':     stop();    break;
      default: engine.turnOn(); engine.color(200, 200, 200); engine.brightness(50);
    }
  }

  void dispose() => _timer?.cancel();
}

// ── App ───────────────────────────────────────────────────────────────────────

class GoveeApp extends StatelessWidget {
  const GoveeApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Govee Light Theater',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: const Color(0xFF0E0E0E)),
      home: const TheaterScreen(),
    );
  }
}

class TheaterScreen extends StatefulWidget {
  const TheaterScreen({super.key});
  @override
  State<TheaterScreen> createState() => _TheaterScreenState();
}

class _TheaterScreenState extends State<TheaterScreen> {
  final _engine = GoveeEngine();
  late final SceneRunner _runner;
  bool _discovering = true;
  bool _found = false;
  @override
  void initState() {
    super.initState();
    _runner = SceneRunner(_engine);
    _doDiscover();
  }

  Future<void> _doDiscover() async {
    setState(() { _discovering = true; _found = false; });
    final ok = await _engine.discover();
    setState(() { _discovering = false; _found = ok; });
  }

  Future<void> _loadSession() async {
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) return;
      final sessionDir = Directory('${dir.path}/session');

      final zipFile = File('${dir.path}/session.zip');
      if (await zipFile.exists()) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(ApiResponseSnackBar(message: 'Extracting session pack…'));
        if (await sessionDir.exists()) await sessionDir.delete(recursive: true);
        await sessionDir.create(recursive: true);
        final bytes = await zipFile.readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);
        for (final entry in archive) {
          if (entry.isFile) {
            final outFile = File('${sessionDir.path}/${entry.name}');
            await outFile.create(recursive: true);
            await outFile.writeAsBytes(entry.content as List<int>);
          }
        }
      }

      final configFile = File('${sessionDir.path}/session.json');
      if (await configFile.exists()) {
        final content = await configFile.readAsString();
        final pack = SessionPack.fromJson(jsonDecode(content), sessionDir.path);
        if (!mounted) return;
        Navigator.push(context, MaterialPageRoute(
          builder: (_) => SessionPerformanceScreen(pack: pack, engine: _engine),
        ));
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(ApiResponseSnackBar(message: 'Place session.zip in /Android/data/.../files/ and try again'));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(ApiResponseSnackBar(message: 'Error: $e'));
    }
  }

  @override
  void dispose() { _runner.dispose(); _engine.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 24),
              if (_discovering) ...[
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 12),
                const Center(child: Text('Searching for light bar…', style: TextStyle(color: Colors.grey))),
              ] else if (!_found)
                Expanded(child: _buildNotFound())
              else
                Expanded(child: _buildSessionHome()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('GOVEE LIGHT THEATER', style: TextStyle(fontSize: 11, color: Colors.grey, letterSpacing: 1.5)),
          SizedBox(height: 4),
          Text('Session Control', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        ])),
        if (_found) GestureDetector(
          onTap: _doDiscover,
          child: Container(width: 10, height: 10, decoration: const BoxDecoration(color: Colors.greenAccent, shape: BoxShape.circle)),
        ),
      ],
    );
  }

  Widget _buildNotFound() {
    return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Icon(Icons.wifi_off, color: Colors.grey, size: 48),
      const SizedBox(height: 16),
      const Text('Light bar not found', style: TextStyle(fontSize: 18)),
      const SizedBox(height: 8),
      const Text('Enable LAN Control in the Govee app.\nWorks on Wi-Fi or phone hotspot.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
      const SizedBox(height: 24),
      ElevatedButton(onPressed: _doDiscover, child: const Text('Try again')),
    ]));
  }

  Widget _buildSessionHome() {
    return Column(
      children: [
        const Spacer(),
        GestureDetector(
          onTap: _loadSession,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 40),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF1a3a1a), Color(0xFF0d2a0d)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.greenAccent.withAlpha(60)),
            ),
            child: const Column(children: [
              Icon(Icons.play_circle_outline, size: 64, color: Colors.greenAccent),
              SizedBox(height: 16),
              Text('Load Session', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              SizedBox(height: 6),
              Text('Place session.zip in app storage', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ]),
          ),
        ),
        const Spacer(),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _showEffectsPanel,
            icon: const Icon(Icons.tune, size: 16, color: Colors.white24),
            label: const Text('Dev effects', style: TextStyle(color: Colors.white24, fontSize: 12)),
          ),
        ),
      ],
    );
  }

  void _showEffectsPanel() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1a1a1a),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _EffectsPanel(runner: _runner),
    );
  }
}

class _EffectsPanel extends StatelessWidget {
  final SceneRunner runner;
  const _EffectsPanel({required this.runner});

  static const _effects = [
    ('off',     'Off',             'Kill all effects',        [Color(0xFF2a2a2a), Color(0xFF1a1a1a)], Colors.grey),
    ('police',  'Police Siren',    'Red / blue rotating',     [Color(0xFFCC0000), Color(0xFF0033DD)], Colors.white),
    ('alarm',   'Emergency Alarm', 'Orange rotating beacon',  [Color(0xFF7a2800), Color(0xFF3a1000)], Color(0xFFFFAA44)),
    ('club',    'Techno Club',     'Pink & green strobe',     [Color(0xFFCC006E), Color(0xFF00CC66)], Colors.white),
    ('flicker', 'Flickering',      'Damaged fluorescent',     [Color(0xFF3a3020), Color(0xFF1a1808)], Color(0xFFD4C080)),
    ('disian',  'Disian',          'Deep purple — metaplane', [Color(0xFF1a0033), Color(0xFF330055)], Color(0xFFCCAAFF)),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 14),
            child: Text('DEV EFFECTS', style: TextStyle(fontSize: 11, color: Colors.grey, letterSpacing: 1.5)),
          ),
          for (final (id, label, sub, gradient, textColor) in _effects)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GestureDetector(
                onTap: () { runner.setByRef(id); Navigator.pop(context); },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: gradient, begin: Alignment.centerLeft, end: Alignment.centerRight),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(label, style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 15)),
                    Text(sub, style: TextStyle(color: textColor.withAlpha(160), fontSize: 12)),
                  ]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class ApiResponseSnackBar extends SnackBar {
  ApiResponseSnackBar({super.key, required String message})
      : super(content: Text(message), duration: const Duration(seconds: 2));
}

// ── Session Performance Screen ────────────────────────────────────────────────

class SessionPerformanceScreen extends StatefulWidget {
  final SessionPack pack;
  final GoveeEngine engine;
  const SessionPerformanceScreen({super.key, required this.pack, required this.engine});
  @override
  State<SessionPerformanceScreen> createState() => _SessionPerformanceScreenState();
}

class _SessionPerformanceScreenState extends State<SessionPerformanceScreen> {
  late final SceneRunner _runner;
  late final AudioEngine _audio;
  int _currentIndex = 0;
  double _spotifyVol = 50, _ambientVol = 50;

  @override
  void initState() {
    super.initState();
    _runner = SceneRunner(widget.engine);
    _audio = AudioEngine();
    _enterScene(0);
  }

  Future<void> _enterScene(int index) async {
    setState(() => _currentIndex = index);
    final scene = widget.pack.arc[index];

    _runner.setByRef(scene.goveeRef);

    if (scene.ambientId != null) {
      final asset = widget.pack.audioManifest[scene.ambientId];
      if (asset != null) {
        final path = '${widget.pack.directoryPath}/${asset.file}';
        await _audio.playAmbient(path, scene.ambientVolume / 100.0);
        setState(() => _ambientVol = scene.ambientVolume.toDouble());
      }
    } else {
      await _audio.setAmbientVolume(0);
    }

    if (scene.spotify.uri.isNotEmpty) {
      try {
        await _wifiChannel.invokeMethod('launchSpotifyUri', scene.spotify.uri).catchError((_) {});
        await _wifiChannel.invokeMethod('setMediaVolume', scene.spotify.volume).catchError((_) {});
        setState(() => _spotifyVol = scene.spotify.volume.toDouble());
      } catch (_) {}
    }
  }

  void _fireTrigger(Trigger t) {
    HapticFeedback.lightImpact();
    final asset = widget.pack.audioManifest[t.soundId];
    if (asset != null) {
      _audio.playTrigger('${widget.pack.directoryPath}/${asset.file}');
    }
    if (t.flashRef != null) {
      _runner.flash(t.flashRef);
    }
  }

  @override
  void dispose() { _runner.dispose(); _audio.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final scene = widget.pack.arc[_currentIndex];
    final prev = _currentIndex > 0 ? widget.pack.arc[_currentIndex - 1] : null;
    final next = _currentIndex < widget.pack.arc.length - 1 ? widget.pack.arc[_currentIndex + 1] : null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Arc Nav
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: prev != null ? () => _enterScene(_currentIndex - 1) : null,
                    child: SizedBox(
                      width: 88,
                      child: Row(children: [
                        Icon(Icons.arrow_back_ios, size: 13, color: prev != null ? Colors.white54 : Colors.white12),
                        const SizedBox(width: 4),
                        Expanded(child: Text(prev?.name ?? '', style: const TextStyle(fontSize: 10, color: Colors.white38), overflow: TextOverflow.ellipsis)),
                      ]),
                    ),
                  ),
                  Expanded(child: Column(children: [
                    Text(scene.name.toUpperCase(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 2), textAlign: TextAlign.center),
                    Text(scene.goveeRef, style: const TextStyle(fontSize: 10, color: Colors.greenAccent)),
                  ])),
                  GestureDetector(
                    onTap: next != null ? () => _enterScene(_currentIndex + 1) : null,
                    child: SizedBox(
                      width: 88,
                      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                        Expanded(child: Text(next?.name ?? '', style: const TextStyle(fontSize: 10, color: Colors.white38), overflow: TextOverflow.ellipsis, textAlign: TextAlign.right)),
                        const SizedBox(width: 4),
                        Icon(Icons.arrow_forward_ios, size: 13, color: next != null ? Colors.white54 : Colors.white12),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12),
            // Trigger Grid
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(24),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2, crossAxisSpacing: 16, mainAxisSpacing: 16, childAspectRatio: 1.8,
                ),
                itemCount: scene.triggers.length,
                itemBuilder: (_, i) {
                  final t = scene.triggers[i];
                  return ElevatedButton(
                    onPressed: () => _fireTrigger(t),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1A1A1A),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(t.name, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  );
                },
              ),
            ),
            // Live Mixer
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              decoration: const BoxDecoration(
                color: Color(0xFF111111),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(children: [
                Row(children: [
                  const Icon(Icons.music_note, size: 18, color: Colors.grey),
                  Expanded(child: Slider(
                    value: _spotifyVol, min: 0, max: 100, activeColor: Colors.greenAccent,
                    onChanged: (v) {
                      setState(() => _spotifyVol = v);
                      _wifiChannel.invokeMethod('setMediaVolume', v.round()).catchError((_) {});
                    },
                  )),
                  Text('${_spotifyVol.round()}%', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 18),
                    color: Colors.grey,
                    onPressed: () => _wifiChannel.invokeMethod('launchSpotifyUri', scene.spotify.uri).catchError((_) {}),
                  ),
                ]),
                Row(children: [
                  const Icon(Icons.waves, size: 18, color: Colors.grey),
                  Expanded(child: Slider(
                    value: _ambientVol, min: 0, max: 100, activeColor: Colors.blueAccent,
                    onChanged: (v) {
                      setState(() => _ambientVol = v);
                      _audio.setAmbientVolume(v / 100.0);
                    },
                  )),
                  Text('${_ambientVol.round()}%', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(width: 44),
                ]),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}
