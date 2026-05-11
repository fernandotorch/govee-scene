import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
  final List<SessionScene> scenes;
  final Map<String, AudioAsset> audioManifest;
  final String directoryPath;

  SessionPack({required this.name, required this.scenes, required this.audioManifest, required this.directoryPath});

  factory SessionPack.fromJson(Map<String, dynamic> json, String dirPath) {
    return SessionPack(
      name: json['name'],
      directoryPath: dirPath,
      scenes: (json['scenes'] as List).map((s) => SessionScene.fromJson(s)).toList(),
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
      AudioAsset(file: json['file'], durationMs: json['duration_ms'] ?? 0);
}

// ── Audio Engine ──────────────────────────────────────────────────────────────

class AudioEngine {
  final AudioPlayer _ambientPlayer = AudioPlayer();
  final List<AudioPlayer> _triggerPlayers = List.generate(6, (_) => AudioPlayer());
  int _triggerIndex = 0;

  AudioEngine() {
    _ambientPlayer.setReleaseMode(ReleaseMode.loop);
    final audioContext = AudioContext(
      android: AudioContextAndroid(
        isSpeakerphoneOn: false,
        stayAwake: false,
        contentType: AndroidContentType.music,
        usageType: AndroidUsageType.media,
        audioFocus: AndroidAudioFocus.none,
      ),
    );
    _ambientPlayer.setAudioContext(audioContext);
    for (final p in _triggerPlayers) {
      p.setAudioContext(audioContext);
    }
  }

  Future<void> playAmbient(String path, double volume) async {
    await _ambientPlayer.stop();
    await _ambientPlayer.setVolume(volume);
    await _ambientPlayer.play(DeviceFileSource(path));
  }

  Future<void> setAmbientVolume(double volume) async {
    await _ambientPlayer.setVolume(volume);
  }

  Future<void> pauseAmbient() async {
    await _ambientPlayer.pause();
  }

  Future<void> resumeAmbient() async {
    await _ambientPlayer.resume();
  }

  double _triggerVolume = 1.0;

  void setTriggerVolume(double volume) { _triggerVolume = volume; }

  Future<AudioPlayer> playTrigger(String path) async {
    final player = _triggerPlayers[_triggerIndex];
    _triggerIndex = (_triggerIndex + 1) % _triggerPlayers.length;
    await player.stop();
    await player.setVolume(_triggerVolume);
    player.play(DeviceFileSource(path)); // intentionally not awaited — return before event fires
    return player;
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
    for (var i = 0; i < 19; i++) { xor ^= pkt[i]; }
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
    engine.segColors([(0, 0, 0, _leftMask | _rightMask)]);
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
      final bright = (22 + v * 58) / 100.0;
      if (_rng.nextDouble() < 0.015) {
        engine.segColors([(170, 179, 217, _leftMask | _rightMask)]);
        return;
      }
      final r = ((65 + v * 45) * bright).round();
      final b = ((105 + v * 95) * bright).round();
      engine.segColors([(r, 0, b, _leftMask | _rightMask)]);
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

  void torches() {
    engine.turnOn(); engine.brightness(100);
    var t = 0.0;
    _loop(const Duration(milliseconds: 120), () {
      t += 0.25;
      final packet = <(int, int, int, int)>[];
      final wind = 0.8 * sin(t * 1.2) + 0.4 * sin(t * 2.8);
      
      for (var h = 0; h < 5; h++) {
        var (br, bg, bb) = (0, 0, 0);
        if (h == 0)      { br = 180; bg = 15;  bb = 0;   }
        else if (h == 1) { br = 220; bg = 55;  bb = 0;   }
        else if (h == 2) { br = 255; bg = 120; bb = 0;   }
        else if (h == 3) { br = 255; bg = 190; bb = 40;  }
        else             { br = 255; bg = 240; bb = 150; }
        
        for (var isRight in [false, true]) {
          final mask = 1 << (h + (isRight ? 5 : 0));
          final barPhase = isRight ? 2.5 : 0.0;
          final flicker = sin(t * 2.5 + barPhase + h * 0.8);
          final sway = isRight ? wind : -wind;
          
          double intensity;
          if (h >= 3) {
            final snap = ((isRight && wind < -0.5) || (!isRight && wind > 0.5)) ? 0.0 : 1.0;
            final agitation = (flicker * 0.7 + 0.3) * snap;
            intensity = agitation * (1.0 + sway.abs() * 0.5);
          } else {
            final glow = (flicker * 0.3 + 0.7);
            intensity = glow * (0.9 + sway.abs() * 0.1);
          }
          
          if (h >= 2 && _rng.nextDouble() < 0.12) {
            intensity *= (1.3 + _rng.nextDouble() * 0.4);
          }
          
          packet.add(((br * intensity).round(), (bg * intensity).round(), (bb * intensity).round(), mask));
        }
      }
      engine.segColors(packet);
    });
  }

  void purpleEvil() {
    _stopLoop(); _cancelled = false;
    final session = _sessionId;
    engine.turnOn(); engine.brightness(100);
    
    Future<void> animation() async {
      var t = 0.0;
      while (!_cancelled && _sessionId == session) {
        if (_rng.nextDouble() < 0.06) {
          final roll = _rng.nextDouble();
          if (roll < 0.40) {
            engine.segColors([(0, 0, 0, _leftMask | _rightMask)]);
            await Future.delayed(Duration(milliseconds: 300 + _rng.nextInt(301)));
            if (_cancelled || _sessionId != session) break;
            engine.segColors([(255, 0, 0, _leftMask | _rightMask)]);
            await Future.delayed(Duration(milliseconds: 200 + _rng.nextInt(201)));
          } else if (roll < 0.70) {
            engine.segColors([(255, 0, 0, _leftMask | _rightMask)]);
            await Future.delayed(Duration(milliseconds: 150 + _rng.nextInt(151)));
            if (_cancelled || _sessionId != session) break;
            engine.segColors([(0, 0, 0, _leftMask | _rightMask)]);
            await Future.delayed(Duration(milliseconds: 400 + _rng.nextInt(401)));
          } else if (roll < 0.90) {
            engine.segColors([(255, 0, 0, _leftMask | _rightMask)]);
            await Future.delayed(Duration(milliseconds: 200 + _rng.nextInt(301)));
          } else {
            engine.segColors([(0, 0, 0, _leftMask | _rightMask)]);
            await Future.delayed(Duration(milliseconds: 300 + _rng.nextInt(401)));
          }
          continue;
        }

        t += 0.3;
        final wind = 0.8 * sin(t * 1.2) + 0.4 * sin(t * 2.8);
        final packet = <(int, int, int, int)>[];
        
        for (var h = 0; h < 5; h++) {
          if (h == 0)      { br = 40;  bg = 0;  bb = 90;  }
          else if (h == 1) { br = 100; bg = 0;  bb = 200; }
          else if (h == 2) { br = 255; bg = 0;  bb = 150; }
          else if (h == 3) { br = 230; bg = 230; bb = 255; }
          else             { br = 255; bg = 10; bb = 0;   }
          
          for (var isRight in [false, true]) {
            final mask = 1 << (h + (isRight ? 5 : 0));
            final barPhase = isRight ? 2.5 : 0.0;
            final flicker = sin(t * 2.5 + barPhase + h * 0.8);
            final sway = isRight ? wind : -wind;
            
            double intensity;
            if (h >= 3) {
              final snap = ((isRight && wind < -0.5) || (!isRight && wind > 0.5)) ? 0.0 : 1.0;
              final agitation = (flicker * 0.7 + 0.3) * snap;
              intensity = agitation * (1.0 + sway.abs() * 0.5);
            } else {
              final glow = (flicker * 0.3 + 0.7);
              intensity = glow * (0.9 + sway.abs() * 0.1);
            }
            
            if (h >= 2 && _rng.nextDouble() < 0.12) {
              intensity *= (1.3 + _rng.nextDouble() * 0.4);
            }
            packet.add(((br * intensity).round(), (bg * intensity).round(), (bb * intensity).round(), mask));
          }
        }
        engine.segColors(packet);
        await Future.delayed(const Duration(milliseconds: 120));
      }
    }
    animation();
  }

  void setByRef(String ref) {
    switch (ref) {
      case 'police':    police();    break;
      case 'alarm':     alarm();     break;
      case 'club':      club();      break;
      case 'flicker':   flicker();   break;
      case 'disian':    disian();    break;
      case 'brave-sea': braveSea();  break;
      case 'torches':   torches();   break;
      case 'evil':      purpleEvil(); break;
      case 'off':       stop();      break;
      default: engine.turnOn(); engine.color(200, 200, 200); engine.brightness(50);
    }
  }
  }

  void dispose() => _timer?.cancel();
}

Future<void> extractAndLoadSession(BuildContext context, Uint8List zipBytes, GoveeEngine engine) async {
  final dir = await getExternalStorageDirectory();
  if (dir == null) return;
  final sessionDir = Directory('${dir.path}/session');
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(ApiResponseSnackBar(message: 'Extracting session pack…'));
  if (await sessionDir.exists()) await sessionDir.delete(recursive: true);
  await sessionDir.create(recursive: true);
  final archive = ZipDecoder().decodeBytes(zipBytes);
  for (final entry in archive) {
    if (entry.isFile) {
      final outFile = File('${sessionDir.path}/${entry.name}');
      await outFile.create(recursive: true);
      await outFile.writeAsBytes(entry.content as List<int>);
    }
  }
  final configFile = File('${sessionDir.path}/session.json');
  if (await configFile.exists()) {
    final content = await configFile.readAsString();
    final pack = SessionPack.fromJson(jsonDecode(content), sessionDir.path);
    if (!context.mounted) return;
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => SessionOverviewScreen(pack: pack, engine: engine),
    ));
  } else {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(ApiResponseSnackBar(message: 'Invalid pack: no session.json'));
  }
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
      final entities = await dir.list().toList();
      final files = entities
          .whereType<File>()
          .where((f) => f.path.endsWith('.zip') && !f.path.endsWith('session.zip'))
          .toList()
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      if (files.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            ApiResponseSnackBar(message: 'No sessions stored. Download one from Studio.'));
        }
        return;
      }
      if (!mounted) return;

      final nameMap = <String, String>{};
      for (final f in files) {
        try {
          final bytes = await f.readAsBytes();
          final archive = ZipDecoder().decodeBytes(bytes);
          ArchiveFile? jsonEntry;
          for (final entry in archive) {
            if (entry.name == 'session.json') { jsonEntry = entry; break; }
          }
          if (jsonEntry != null) {
            final data = jsonDecode(utf8.decode(jsonEntry.content as List<int>)) as Map<String, dynamic>;
            nameMap[f.path] = data['name'] as String? ?? f.uri.pathSegments.last.replaceAll('.zip', '');
          }
        } catch (_) {
          nameMap[f.path] = f.uri.pathSegments.last.replaceAll('.zip', '');
        }
      }

      if (!mounted) return;
      await showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF1A1A1A),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        isScrollControlled: true,
        builder: (ctx) => SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.85,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Text('STORED SESSIONS',
                  style: TextStyle(fontSize: 11, letterSpacing: 1.5, color: Colors.grey)),
              ),
              Expanded(
                child: ListView(
                  children: files.map((f) {
                    final name = nameMap[f.path] ?? f.uri.pathSegments.last.replaceAll('.zip', '');
                    return ListTile(
                      leading: const Icon(Icons.bolt, color: Color(0xFF63B8DE)),
                      title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                      onTap: () async {
                        Navigator.pop(ctx);
                        final bytes = await f.readAsBytes();
                        if (!context.mounted) return;
                        // ignore: use_build_context_synchronously
                        await extractAndLoadSession(context, bytes, _engine);
                      },
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          ApiResponseSnackBar(message: 'Error: $e'));
      }
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
          child: Container(width: 10, height: 10, decoration: const BoxDecoration(color: Color(0xFF63B8DE), shape: BoxShape.circle)),
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
                colors: [Color(0xFF0a1a2a), Color(0xFF051a2a)],
                begin: Alignment.topLeft, end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Color(0xFF63B8DE).withAlpha(60)),
            ),
            child: const Column(children: [
              Icon(Icons.play_circle_outline, size: 64, color: Color(0xFF63B8DE)),
              SizedBox(height: 16),
              Text('Load Session', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              SizedBox(height: 6),
              Text('Tap to browse stored sessions', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: () => Navigator.push(context, MaterialPageRoute(
            builder: (_) => StudioBrowserScreen(engine: _engine),
          )),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 28),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF0a1a2a), Color(0xFF051a2a)],
                begin: Alignment.topLeft, end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Color(0xFF63B8DE).withAlpha(60)),
            ),
            child: const Column(children: [
              Icon(Icons.cloud_download_outlined, size: 48, color: Color(0xFF63B8DE)),
              SizedBox(height: 12),
              Text('Browse Studio', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              SizedBox(height: 4),
              Text('Download from local Flask server', style: TextStyle(fontSize: 12, color: Colors.grey)),
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
    ('off',       'Off',             'Kill all effects',        [Color(0xFF2a2a2a), Color(0xFF1a1a1a)], Colors.grey),
    ('police',    'Police Siren',    'Red / blue rotating',     [Color(0xFFCC0000), Color(0xFF0033DD)], Colors.white),
    ('alarm',     'Emergency Alarm', 'Orange rotating beacon',  [Color(0xFF7a2800), Color(0xFF3a1000)], Color(0xFFFFAA44)),
    ('brave-sea', 'Brave Sea',      'High-action oceanic',     [Color(0xFF00021e), Color(0xFF001e3c)], Color(0xFF63B8DE)),
    ('torches',   'Torch Fire',      'Independent fire flickers', [Color(0xFF3a1000), Color(0xFF7a2800)], Color(0xFFFFAA44)),
    ('evil',      'Torch Fire Evil', 'Malevolent purple flames', [Color(0xFF1a0033), Color(0xFF660099)], Color(0xFFFF00FF)),
    ('club',      'Techno Club',     'Pink & green strobe',     [Color(0xFFCC006E), Color(0xFF00CC66)], Colors.white),
    ('flicker',   'Flickering',      'Damaged fluorescent',     [Color(0xFF3a3020), Color(0xFF1a1808)], Color(0xFFD4C080)),
    ('disian',    'Disian',          'Deep purple — metaplane', [Color(0xFF1a0033), Color(0xFF330055)], Color(0xFFCCAAFF)),
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

class StudioBrowserScreen extends StatefulWidget {
  final GoveeEngine engine;
  const StudioBrowserScreen({super.key, required this.engine});
  @override
  State<StudioBrowserScreen> createState() => _StudioBrowserScreenState();
}

class _StudioBrowserScreenState extends State<StudioBrowserScreen> {
  final _ipController = TextEditingController();
  List<Map<String, String>> _packs = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSavedIp();
  }

  @override
  void dispose() {
    _ipController.dispose();
    super.dispose();
  }

  Future<File> get _prefsFile async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/studio_prefs.json');
  }

  Future<void> _loadSavedIp() async {
    try {
      final f = await _prefsFile;
      if (await f.exists()) {
        final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        setState(() => _ipController.text = data['ip'] as String? ?? '');
      }
    } catch (_) {}
  }

  Future<void> _saveIp(String ip) async {
    try {
      final f = await _prefsFile;
      await f.writeAsString(jsonEncode({'ip': ip}));
    } catch (_) {}
  }

  Future<void> _connect() async {
    final ip = _ipController.text.trim();
    if (ip.isEmpty) return;
    await _saveIp(ip);
    setState(() { _loading = true; _error = null; _packs = []; });
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final request = await client.getUrl(Uri.parse('http://$ip:5000/api/packs'));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close();
      if (response.statusCode == 200) {
        final list = jsonDecode(body) as List;
        setState(() {
          _packs = list.map((e) => {
            'filename': e['filename'] as String,
            'display_name': e['display_name'] as String,
          }).toList();
          _loading = false;
        });
      } else {
        setState(() { _error = 'Server error ${response.statusCode}'; _loading = false; });
      }
    } catch (e) {
      setState(() { _error = 'Could not reach Studio: $e'; _loading = false; });
    }
  }

  Future<void> _downloadAndLoad(String filename) async {
    final ip = _ipController.text.trim();
    setState(() { _loading = true; _error = null; });
    try {
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse('http://$ip:5000/api/packs/$filename'));
      final response = await request.close();
      final chunks = <List<int>>[];
      await response.forEach((chunk) => chunks.add(chunk));
      client.close();
      final bytes = Uint8List.fromList(chunks.expand((x) => x).toList());
      final saveDir = await getExternalStorageDirectory();
      if (saveDir != null) {
        await File('${saveDir.path}/$filename').writeAsBytes(bytes);
      }
      if (!mounted) return;
      Navigator.pop(context);
      await extractAndLoadSession(context, bytes, widget.engine);
    } catch (e) {
      setState(() { _error = 'Download failed: $e'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Browse Studio', style: TextStyle(fontSize: 16, letterSpacing: 1)),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('STUDIO IP', style: TextStyle(fontSize: 11, color: Colors.grey, letterSpacing: 1.5)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: TextField(
                controller: _ipController,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: InputDecoration(
                  hintText: '192.168.x.x',
                  hintStyle: const TextStyle(color: Colors.white24),
                  filled: true,
                  fillColor: const Color(0xFF1A1A1A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                ),
                onSubmitted: (_) => _connect(),
              )),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: _loading ? null : _connect,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF63B8DE),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                ),
                child: const Text('Connect', style: TextStyle(color: Colors.white)),
              ),
            ]),
            const SizedBox(height: 24),
            if (_loading) const Center(child: CircularProgressIndicator(color: Color(0xFF63B8DE)))
            else if (_error != null)
              Center(child: Text(_error!, style: const TextStyle(color: Colors.redAccent)))
            else if (_packs.isEmpty && _ipController.text.isNotEmpty)
              const Center(child: Text('No sessions found', style: TextStyle(color: Colors.grey)))
            else
              Expanded(child: ListView.separated(
                itemCount: _packs.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final pack = _packs[i];
                  return GestureDetector(
                    onTap: () => _downloadAndLoad(pack['filename']!),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A1A),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(children: [
                        const Icon(Icons.bolt, color: Color(0xFF63B8DE)),
                        const SizedBox(width: 12),
                        Expanded(child: Text(pack['display_name']!, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
                        const Icon(Icons.download, color: Colors.white38, size: 18),
                      ]),
                    ),
                  );
                },
              )),
          ],
        ),
      ),
    );
  }
}

// ── Session Overview Screen ───────────────────────────────────────────────────

class SessionOverviewScreen extends StatelessWidget {
  final SessionPack pack;
  final GoveeEngine engine;
  const SessionOverviewScreen({super.key, required this.pack, required this.engine});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(pack.name, style: const TextStyle(fontSize: 16, letterSpacing: 0.5)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => SessionPerformanceScreen(pack: pack, engine: engine),
            )),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF0a1a2a), Color(0xFF051a2a)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Color(0xFF63B8DE).withAlpha(50)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.play_circle_outline, color: Color(0xFF63B8DE), size: 28),
                    const SizedBox(width: 12),
                    Expanded(child: Text(
                      pack.name,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    )),
                    Text(
                      '${pack.scenes.length} scenes',
                      style: const TextStyle(fontSize: 12, color: Colors.white38),
                    ),
                  ]),
                  const SizedBox(height: 14),
                  ...pack.scenes.asMap().entries.map((e) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(children: [
                      SizedBox(
                        width: 22,
                        child: Text('${e.key + 1}.',
                          style: const TextStyle(fontSize: 11, color: Colors.white24),
                          textAlign: TextAlign.right),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(e.value.name,
                        style: const TextStyle(fontSize: 13, color: Colors.white70))),
                      Text(e.value.goveeRef,
                        style: const TextStyle(fontSize: 10, color: Color(0xFF63B8DE))),
                    ]),
                  )),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Session Performance Screen ────────────────────────────────────────────────

class SessionPerformanceScreen extends StatefulWidget {
  final SessionPack pack;
  final GoveeEngine engine;
  const SessionPerformanceScreen({super.key, required this.pack, required this.engine});
  @override
  State<SessionPerformanceScreen> createState() => _SessionPerformanceScreenState();
}

class _SessionPerformanceScreenState extends State<SessionPerformanceScreen> with TickerProviderStateMixin {
  late final SceneRunner _runner;
  late final AudioEngine _audio;
  int _currentIndex = 0;
  double _ambientVol = 50, _triggerVol = 80;
  bool _spotifyPaused = false;
  bool _isPaused = false;
  bool _hasScene = false;



  Future<void> _rampAmbient(double from, double to) async {
    const steps = 8; const stepMs = 50;
    for (int i = 1; i <= steps; i++) {
      final v = from + (to - from) * i / steps;
      await _audio.setAmbientVolume(v);
      if (i < steps) await Future.delayed(const Duration(milliseconds: stepMs));
    }
  }
  final Map<int, AnimationController> _activeTriggers = {};

  @override
  void initState() {
    super.initState();
    _runner = SceneRunner(widget.engine);
    _audio = AudioEngine();
    _enterScene(0);
  }

  Future<void> _enterScene(int index) async {
    _isPaused = false;
    final scene = widget.pack.scenes[index];

    // Fade out ambient only — do not touch Spotify volume (causes bell + hangs)
    if (_hasScene) {
      await _rampAmbient(_ambientVol / 100.0, 0.0);
    }
    _hasScene = true;

    setState(() => _currentIndex = index);
    _runner.setByRef(scene.goveeRef);

    // Switch ambient track at silence
    if (scene.ambientId != null) {
      final asset = widget.pack.audioManifest[scene.ambientId];
      if (asset != null) {
        final path = '${widget.pack.directoryPath}/${asset.file}';
        await _audio.playAmbient(path, 0.0);
      }
    } else {
      await _audio.setAmbientVolume(0);
    }

    // Switch Spotify instantly then set target volume in one call
    if (scene.spotify.uri.isNotEmpty) {
      await _wifiChannel.invokeMethod('spotifyPlay', scene.spotify.uri).catchError((_) {});
      setState(() => _spotifyPaused = false);
    }

    // Fade ambient in
    final targetAmbient = scene.ambientId != null ? scene.ambientVolume / 100.0 : 0.0;
    await _rampAmbient(0.0, targetAmbient);
    setState(() => _ambientVol = scene.ambientVolume.toDouble());
  }

  void _fireTrigger(Trigger t, int index) async {
    HapticFeedback.lightImpact();
    if (t.soundId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No sound assigned to this trigger')));
      return;
    }
    final asset = widget.pack.audioManifest[t.soundId];
    if (asset == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sound not found: ${t.soundId}')));
      return;
    }
    if (t.flashRef != null) _runner.flash(t.flashRef);

    final path = '${widget.pack.directoryPath}/${asset.file}';
    try {
      final ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 10));
      _activeTriggers[index]?.dispose();
      setState(() => _activeTriggers[index] = ctrl);

      final player = await _audio.playTrigger(path);

      Future.any([
        player.onDurationChanged.first,
        Future.delayed(const Duration(milliseconds: 500), () => Duration.zero),
      ]).then((d) {
        if (!mounted) return;
        ctrl.duration = d.inMilliseconds > 0 ? d : const Duration(seconds: 5);
        ctrl.forward();
      });

      player.onPlayerComplete.first.then((_) {
        if (mounted) setState(() => _activeTriggers.remove(index)?.dispose());
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Playback error: $e')));
    }
  }

  void _togglePause() {
    setState(() => _isPaused = !_isPaused);
    if (_isPaused) {
      _runner.stop();
      _audio.pauseAmbient();
      _wifiChannel.invokeMethod('spotifyPause', null).catchError((_) {});
    } else {
      _runner.setByRef(widget.pack.scenes[_currentIndex].goveeRef);
      _audio.resumeAmbient();
      _wifiChannel.invokeMethod('spotifyResume', null).catchError((_) {});
    }
  }

  void _toggleSpotify() {
    setState(() => _spotifyPaused = !_spotifyPaused);
    if (_spotifyPaused) {
      _wifiChannel.invokeMethod('spotifyPause', null).catchError((_) {});
    } else {
      _wifiChannel.invokeMethod('spotifyResume', null).catchError((_) {});
    }
  }

  @override
  void dispose() {
    for (final c in _activeTriggers.values) { c.dispose(); }
    _runner.dispose();
    _audio.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scene = widget.pack.scenes[_currentIndex];
    final prev = _currentIndex > 0 ? widget.pack.scenes[_currentIndex - 1] : null;
    final int nextIndex = (_currentIndex + 1) % widget.pack.scenes.length;
    final next = widget.pack.scenes.length > 1 ? widget.pack.scenes[nextIndex] : null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Scene Nav
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
                    Text(scene.goveeRef, style: const TextStyle(fontSize: 10, color: Color(0xFF63B8DE))),
                  ])),
                  GestureDetector(
                    onTap: next != null ? () => _enterScene(nextIndex) : null,
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
            Center(
              child: IconButton(
                icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause, size: 32),
                color: _isPaused ? const Color(0xFF63B8DE) : Colors.white54,
                tooltip: _isPaused ? 'Resume' : 'Pause',
                onPressed: _togglePause,
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
                  return Stack(
                    children: [
                      SizedBox.expand(
                        child: ElevatedButton(
                          onPressed: () => _fireTrigger(t, i),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1A1A1A),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: Text(t.name, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        ),
                      ),
                      if (_activeTriggers.containsKey(i))
                        Positioned.fill(
                          child: IgnorePointer(
                            child: AnimatedBuilder(
                              animation: _activeTriggers[i]!,
                              builder: (_, _) => CustomPaint(
                                painter: _TriggerBorderPainter(_activeTriggers[i]!.value),
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ),
                        ),
                    ],
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
                  const Expanded(
                    child: Text('Spotify', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ),
                  IconButton(
                    icon: Icon(
                      _spotifyPaused ? Icons.play_arrow : Icons.pause,
                      size: 20,
                    ),
                    color: _spotifyPaused ? const Color(0xFF63B8DE) : Colors.grey,
                    onPressed: _toggleSpotify,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  const SizedBox(width: 24),
                ]),
                Row(children: [
                  const Icon(Icons.waves, size: 18, color: Colors.grey),
                  Expanded(child: Slider(
                    value: _ambientVol, min: 0, max: 100, activeColor: const Color(0xFF63B8DE),
                    onChanged: (v) {
                      setState(() => _ambientVol = v);
                      _audio.setAmbientVolume(v / 100.0);
                    },
                  )),
                  Text('${_ambientVol.round()}%', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(width: 44),
                ]),
                Row(children: [
                  const Icon(Icons.bolt, size: 18, color: Colors.grey),
                  Expanded(child: Slider(
                    value: _triggerVol, min: 0, max: 100, activeColor: const Color(0xFF63B8DE),
                    onChanged: (v) {
                      setState(() => _triggerVol = v);
                      _audio.setTriggerVolume(v / 100.0);
                    },
                  )),
                  Text('${_triggerVol.round()}%', style: const TextStyle(fontSize: 12, color: Colors.grey)),
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

class _TriggerBorderPainter extends CustomPainter {
  final double progress;
  _TriggerBorderPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final paint = Paint()
      ..color = const Color(0xFF63B8DE)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.butt;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(1.5, 1.5, size.width - 3, size.height - 3),
      const Radius.circular(12),
    );
    final path = Path()..addRRect(rrect);
    final metrics = path.computeMetrics().first;
    final drawn = metrics.extractPath(0, metrics.length * progress.clamp(0, 1));
    canvas.drawPath(drawn, paint);
  }

  @override
  bool shouldRepaint(_TriggerBorderPainter old) => old.progress != progress;
}
