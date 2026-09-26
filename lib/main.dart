import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';

import 'package:crypto/crypto.dart';

import 'client_lobby_screen.dart';
import 'spotify_service.dart';
import 'session_controller.dart';
import 'session_model.dart';
import 'session_renderer.dart';
import 'sync_client.dart';
import 'sync_host.dart';
import 'sync_protocol.dart';

final RouteObserver<ModalRoute<void>> routeObserver = RouteObserver<ModalRoute<void>>();

Future<Directory> packStorageDir() async {
  if (Platform.isAndroid) return (await getExternalStorageDirectory())!;
  final dir = Directory('${(await getApplicationSupportDirectory()).path}/sessions');
  await dir.create(recursive: true);
  return dir;
}

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


// ── Audio Engine ──────────────────────────────────────────────────────────────

class AudioEngine {
  final AudioPlayer _ambientPlayer = AudioPlayer();
  final List<AudioPlayer> _triggerPlayers = List.generate(6, (_) => AudioPlayer());
  int _triggerIndex = 0;

  AudioEngine() {
    _ambientPlayer.setReleaseMode(ReleaseMode.loop);

    // The bed loops forever, so it must never take audio focus — it would hold
    // the duck open permanently.
    final ambientContext = AudioContext(
      android: AudioContextAndroid(
        isSpeakerphoneOn: false,
        stayAwake: false,
        contentType: AndroidContentType.music,
        usageType: AndroidUsageType.media,
        audioFocus: AndroidAudioFocus.none,
      ),
    );

    // Triggers request transient ducking focus. Android tells Spotify to duck
    // itself (~-14 dB) for as long as we hold focus; audioplayers releases focus
    // on natural completion (WrappedPlayer.onCompletion -> stop -> handleStop).
    final triggerContext = AudioContext(
      android: AudioContextAndroid(
        isSpeakerphoneOn: false,
        stayAwake: false,
        contentType: AndroidContentType.music,
        usageType: AndroidUsageType.media,
        audioFocus: AndroidAudioFocus.gainTransientMayDuck,
      ),
    );

    if (Platform.isAndroid || Platform.isIOS) {
      _ambientPlayer.setAudioContext(ambientContext);
      for (final p in _triggerPlayers) {
        p.setAudioContext(triggerContext);
      }
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

  Future<void> stopTriggers() async {
    for (final p in _triggerPlayers) {
      await p.stop();
    }
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

class GoveeEngine extends ChangeNotifier {
  InternetAddress? _deviceIp; bool _isDiscovering = false; bool get isDiscovering => _isDiscovering; bool get hasDevice => _deviceIp != null;
  RawDatagramSocket? _socket;

  Future<bool> discover() async {
    _isDiscovering = true; notifyListeners();
    _isDiscovering = true; notifyListeners();
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

  Future<void>? _initFuture;
  Future<void> _initSocket() async {
    if (_initFuture != null) return _initFuture;
    final completer = Completer<void>();
    _initFuture = completer.future;
    try {
      _socket?.close();
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      completer.complete();
    } catch (e) {
      completer.completeError(e);
    } finally {
      _initFuture = null;
    }
    return completer.future;
  }

  int _errorCount = 0;
  DateTime _lastSend = DateTime.fromMillisecondsSinceEpoch(0);

  void _send(Map<String, dynamic> cmd) {
    if (_deviceIp == null) return;
    
    // Rate limit to prevent clogging the device (max ~15-20 Hz)
    final now = DateTime.now();
    if (now.difference(_lastSend).inMilliseconds < 40) return;
    _lastSend = now;

    if (_socket == null) {
      _initSocket().then((_) => _send(cmd)).catchError((_) {});
      return;
    }
    try {
      final payload = utf8.encode(jsonEncode({"msg": cmd}));
      final sent = _socket!.send(payload, _deviceIp!, _controlPort);
      if (sent <= 0) {
        _errorCount++;
        if (_errorCount > 5) {
          _errorCount = 0;
          _initSocket();
        }
      } else {
        _errorCount = 0;
      }
    } catch (_) {
      _errorCount++;
      _initSocket().then((_) => _send(cmd)).catchError((_) {});
    }
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

  @override
  void dispose() {
    _socket?.close();
    super.dispose();
  }
}

// ── Scene runner ──────────────────────────────────────────────────────────────

class SceneRunner {
  Timer? _flashTimer;
  final GoveeEngine engine;
  Timer? _timer;
  bool _cancelled = false;
  int _sessionId = 0;
  final _rng = Random();
  String _currentRef = 'off';

  SceneRunner(this.engine);

  void _stopLoop() {
    _cancelled = true;
    _sessionId++;
    _timer?.cancel();
    _timer = null;
    _flashTimer?.cancel();
    _flashTimer = null;
    _cancelled = true;
  }

  void stop() {
    _stopLoop();
    engine.segColors([(0, 0, 0, _leftMask | _rightMask)]);
    engine.turnOff();
  }

  void _loop(Duration interval, void Function() fn) {
    _stopLoop();
    _cancelled = false;
    Timer(const Duration(milliseconds: 45), () { if (!_cancelled) fn(); });
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
    _loop(const Duration(milliseconds: 120), () {
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
    _flashTimer?.cancel();
    _timer?.cancel();
    if (ref == 'white-burst') {
      engine.color(255, 255, 255);
      _flashTimer = Timer(const Duration(milliseconds: 200), () => setByRef(_currentRef));
    } else if (ref == 'orange-burst') {
      engine.color(255, 100, 0);
      _flashTimer = Timer(const Duration(milliseconds: 200), () => setByRef(_currentRef));
    } else if (ref == 'purple-pulse') {
      engine.color(180, 0, 255);
      _flashTimer = Timer(const Duration(milliseconds: 300), () => setByRef(_currentRef));
    } else if (ref == 'fire-spark') {
      engine.color(255, 200, 50);
      _flashTimer = Timer(const Duration(milliseconds: 300), () => setByRef(_currentRef));
    } else if (ref == 'red-spark') {
      engine.color(255, 30, 20);
      _flashTimer = Timer(const Duration(milliseconds: 300), () => setByRef(_currentRef));
    } else if (ref == 'blue-spark') {
      engine.color(50, 150, 255);
      _flashTimer = Timer(const Duration(milliseconds: 300), () => setByRef(_currentRef));
    } else if (ref == 'green-spark') {
      engine.color(0, 255, 80);
      _flashTimer = Timer(const Duration(milliseconds: 300), () => setByRef(_currentRef));
    } else if (ref == 'smg-burst') {
      engine.color(255, 240, 180);
      Timer(const Duration(milliseconds: 105), () { engine.color(255, 150, 10); });
      Timer(const Duration(milliseconds: 210), () { engine.color(255, 240, 180); });
      Timer(const Duration(milliseconds: 315), () { engine.color(255, 150, 10); });
      Timer(const Duration(milliseconds: 420), () { engine.color(255, 240, 180); });
      Timer(const Duration(milliseconds: 525), () { engine.color(255, 150, 10); });
      Timer(const Duration(milliseconds: 630), () { engine.color(255, 240, 180); });
      Timer(const Duration(milliseconds: 735), () { engine.color(255, 150, 10); });
      _flashTimer = Timer(const Duration(milliseconds: 840), () => setByRef(_currentRef));
    } else if (ref == 'pulse-rifle') {
      engine.color(30, 90, 255);
      Timer(const Duration(milliseconds: 600), () { engine.color(230, 255, 255); });
      Timer(const Duration(milliseconds: 750), () { engine.color(0, 255, 80); });
      _flashTimer = Timer(const Duration(milliseconds: 950), () => setByRef(_currentRef));
    } else if (ref == 'flamethrower') {
      engine.color(255, 220, 80);
      Timer(const Duration(milliseconds:   80), () { engine.color(255,  80,  0); });
      Timer(const Duration(milliseconds:  195), () { engine.color(255, 160, 20); });
      Timer(const Duration(milliseconds:  310), () { engine.color(255,  55,  0); });
      Timer(const Duration(milliseconds:  425), () { engine.color(255, 175, 25); });
      Timer(const Duration(milliseconds:  540), () { engine.color(255,  65,  0); });
      Timer(const Duration(milliseconds:  655), () { engine.color(255, 145, 10); });
      Timer(const Duration(milliseconds:  770), () { engine.color(220,  45,  0); });
      Timer(const Duration(milliseconds:  885), () { engine.color(255, 110,  5); });
      Timer(const Duration(milliseconds: 1100), () { engine.color( 20,   5,  0); });
      Timer(const Duration(milliseconds: 1380), () { engine.color(255, 220, 80); });
      Timer(const Duration(milliseconds: 1500), () { engine.color(255,  80,  0); });
      Timer(const Duration(milliseconds: 1672), () { engine.color(255, 160, 20); });
      Timer(const Duration(milliseconds: 1844), () { engine.color(255,  55,  0); });
      Timer(const Duration(milliseconds: 2016), () { engine.color(255, 175, 25); });
      Timer(const Duration(milliseconds: 2188), () { engine.color(255,  65,  0); });
      Timer(const Duration(milliseconds: 2360), () { engine.color(255, 145, 10); });
      Timer(const Duration(milliseconds: 2532), () { engine.color(220,  45,  0); });
      Timer(const Duration(milliseconds: 2704), () { engine.color(255, 110,  5); });
      Timer(const Duration(milliseconds: 2876), () { engine.color(150,  18,  0); });
      _flashTimer = Timer(const Duration(milliseconds: 3251), () => setByRef(_currentRef));
    } else if (ref == 'bio-burst') {
      // Phase 1 — pressure build → white-pink burst → first decay
      engine.color(130, 0, 15);
      Timer(const Duration(milliseconds:  200), () { engine.color(180,   5,  20); });
      Timer(const Duration(milliseconds:  400), () { engine.color(230,  10,  25); });
      Timer(const Duration(milliseconds:  600), () { engine.color( 15,   0,   5); });
      Timer(const Duration(milliseconds:  700), () { engine.color(255, 180, 160); });
      Timer(const Duration(milliseconds:  800), () { engine.color(255,   0,  10); });
      Timer(const Duration(milliseconds:  900), () { engine.color( 20,   0,   5); });
      Timer(const Duration(milliseconds: 1000), () { engine.color(210,   0,  15); });
      Timer(const Duration(milliseconds: 1100), () { engine.color( 15,   0,   3); });
      Timer(const Duration(milliseconds: 1300), () { engine.color( 70,   0,  10); });
      // Phase 2 — low simmer → compression → rapid red/dark finale → fade
      Timer(const Duration(milliseconds: 1600), () { engine.color(150,   0,  10); });
      Timer(const Duration(milliseconds: 2000), () { engine.color(200,   0,  15); });
      Timer(const Duration(milliseconds: 2450), () { engine.color(230,   5,  15); });
      Timer(const Duration(milliseconds: 2800), () { engine.color(175,   0,  12); });
      Timer(const Duration(milliseconds: 3100), () { engine.color(230,   5,  15); });
      Timer(const Duration(milliseconds: 3450), () { engine.color(178,   0,  12); });
      Timer(const Duration(milliseconds: 3750), () { engine.color(228,   5,  15); });
      Timer(const Duration(milliseconds: 4100), () { engine.color(175,   0,  11); });
      Timer(const Duration(milliseconds: 4400), () { engine.color(220,   5,  14); });
      Timer(const Duration(milliseconds: 4650), () { engine.color( 15,   0,   3); });
      Timer(const Duration(milliseconds: 4850), () { engine.color(255,   0,  10); });
      Timer(const Duration(milliseconds: 4930), () { engine.color( 10,   0,   2); });
      Timer(const Duration(milliseconds: 5010), () { engine.color(255,   0,  10); });
      Timer(const Duration(milliseconds: 5090), () { engine.color( 10,   0,   2); });
      Timer(const Duration(milliseconds: 5170), () { engine.color(240,   0,   8); });
      Timer(const Duration(milliseconds: 5250), () { engine.color( 10,   0,   2); });
      Timer(const Duration(milliseconds: 5330), () { engine.color(220,   0,   8); });
      Timer(const Duration(milliseconds: 5410), () { engine.color( 10,   0,   2); });
      Timer(const Duration(milliseconds: 5490), () { engine.color(200,   0,   6); });
      Timer(const Duration(milliseconds: 5590), () { engine.color( 10,   0,   2); });
      Timer(const Duration(milliseconds: 5690), () { engine.color(170,   0,   5); });
      Timer(const Duration(milliseconds: 5810), () { engine.color( 10,   0,   2); });
      Timer(const Duration(milliseconds: 5930), () { engine.color(130,   0,   4); });
      Timer(const Duration(milliseconds: 6230), () { engine.color( 10,   0,   2); });
      Timer(const Duration(milliseconds: 6580), () { engine.color( 80,   0,   3); });
      Timer(const Duration(milliseconds: 6980), () { engine.color( 10,   0,   2); });
      Timer(const Duration(milliseconds: 7380), () { engine.color( 30,   0,   1); });
      Timer(const Duration(milliseconds: 7880), () { engine.color(  8,   0,   0); });
      Timer(const Duration(milliseconds: 8580), () { engine.color( 15,   0,   0); });
      Timer(const Duration(milliseconds: 9280), () { engine.color(  4,   0,   0); });
      Timer(const Duration(milliseconds: 9880), () { engine.color( 10,   0,   0); });
      Timer(const Duration(milliseconds: 10580), () { engine.color(  2,   0,   0); });
      _flashTimer = Timer(const Duration(milliseconds: 11280), () => setByRef(_currentRef));
    } else if (ref == 'rose-pulse') {
      engine.segColors([(255, 85, 93, _leftMask | _rightMask)]);
      Timer(const Duration(milliseconds: 200), () {
        engine.segColors([(89, 30, 33, _leftMask | _rightMask)]);
        Timer(const Duration(milliseconds: 300), () {
          engine.segColors([(255, 85, 93, _leftMask | _rightMask)]);
          _flashTimer = Timer(const Duration(milliseconds: 230), () => setByRef(_currentRef));
        });
      });
    }
  }

  void braveSea() {
    engine.turnOn(); engine.brightness(100);
    var t = 0.0;
    _loop(const Duration(milliseconds: 120), () {
      t += 0.6;
      final crestBase = (t % 3.5) - 1.5;
      final splash = _rng.nextDouble() < 0.15;
      final packet = <(int, int, int, int)>[];
      
      for (var i = 0; i < 10; i++) {
        final mask = 1 << i;
        final idx = i % 5;
        final crestPos = (i < 5) ? crestBase : ((t * 1.1 + 1.5) % 3.2) - 1.5;
        final dist = (idx - crestPos).abs();
        
        var (r, g, b) = (0, 2, 30);
        if (dist < 1.0) {
          final v = 1.0 - dist;
          r = (r + (200 - r) * v).round();
          g = (g + (240 - g) * v).round();
          b = (b + (255 - b) * v).round();
        }
        if (splash && _rng.nextDouble() < 0.4) {
          r = 230; g = 250; b = 255;
        }
        packet.add((r, g, b, mask));
      }
      
      engine.segColors(packet);
    });
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
            if (_cancelled || _sessionId != session) break;
          } else if (roll < 0.70) {
            engine.segColors([(255, 0, 0, _leftMask | _rightMask)]);
            await Future.delayed(Duration(milliseconds: 150 + _rng.nextInt(151)));
            if (_cancelled || _sessionId != session) break;
            engine.segColors([(0, 0, 0, _leftMask | _rightMask)]);
            await Future.delayed(Duration(milliseconds: 400 + _rng.nextInt(401)));
            if (_cancelled || _sessionId != session) break;
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
          var br = 0, bg = 0, bb = 0;
          if (h == 0)      { br = 40;  bg = 0;  bb = 90;  }
          else if (h == 1) { br = 100; bg = 0;  bb = 200; }
          else if (h == 2) { br = 255; bg = 0;  bb = 150; }
          else if (h == 3) { br = 230; bg = 230; bb = 255; }
          else             { br = 255; bg = 100; bb = 255; } // Bright Magenta Tip
          
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

  void flickerSlow() {
    _stopLoop(); _cancelled = false;
    final session = _sessionId;
    engine.turnOn();
    Future<void> barLoop(int mask, int startDelayMs) async {
      await Future.delayed(Duration(milliseconds: startDelayMs));
      if (_cancelled || _sessionId != session) return;
      while (!_cancelled && _sessionId == session) {
        try {
          engine.segColors([(240, 230, 200, mask)]);
          await Future.delayed(Duration(milliseconds: 10000 + _rng.nextInt(10001)));
          if (_cancelled || _sessionId != session) break;
          var remaining = 300 + _rng.nextInt(701);
          while (remaining > 0 && !_cancelled && _sessionId == session) {
            final cut = min(remaining, 200 + _rng.nextInt(301));
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
    barLoop(_leftMask, 60); barLoop(_rightMask, 110);
  }

  void flickerPink() {
    _stopLoop(); _cancelled = false;
    final session = _sessionId;
    engine.turnOn();
    Future<void> barLoop(int mask, int startDelayMs) async {
      await Future.delayed(Duration(milliseconds: startDelayMs));
      if (_cancelled || _sessionId != session) return;
      while (!_cancelled && _sessionId == session) {
        try {
          engine.segColors([(255, 0, 180, mask)]);
          await Future.delayed(Duration(milliseconds: 10000 + _rng.nextInt(10001)));
          if (_cancelled || _sessionId != session) break;
          var remaining = 300 + _rng.nextInt(701);
          while (remaining > 0 && !_cancelled && _sessionId == session) {
            final cut = min(remaining, 200 + _rng.nextInt(301));
            engine.segColors([(2, 0, 1, mask)]);
            await Future.delayed(Duration(milliseconds: cut));
            remaining -= cut;
            if (_cancelled || _sessionId != session || remaining <= 0) break;
            engine.segColors([(255, 0, 180, mask)]);
            await Future.delayed(Duration(milliseconds: 40 + _rng.nextInt(81)));
          }
          if (!_cancelled && _sessionId == session) engine.segColors([(255, 0, 180, mask)]);
        } catch (_) {}
      }
    }
    barLoop(_leftMask, 60); barLoop(_rightMask, 110);
  }

  void neonMotel() {
    _stopLoop(); _cancelled = false;
    final session = _sessionId;
    engine.turnOn();
    Future<void> barLoop(int r, int g, int b, int mask, int startDelayMs) async {
      await Future.delayed(Duration(milliseconds: startDelayMs));
      if (_cancelled || _sessionId != session) return;
      while (!_cancelled && _sessionId == session) {
        try {
          engine.segColors([(r, g, b, mask)]);
          await Future.delayed(Duration(milliseconds: 4000 + _rng.nextInt(6001)));
          if (_cancelled || _sessionId != session) break;
          var remaining = 300 + _rng.nextInt(701);
          while (remaining > 0 && !_cancelled && _sessionId == session) {
            final cut = min(remaining, 200 + _rng.nextInt(301));
            engine.segColors([(2, 2, 2, mask)]);
            await Future.delayed(Duration(milliseconds: cut));
            remaining -= cut;
            if (_cancelled || _sessionId != session || remaining <= 0) break;
            engine.segColors([(r, g, b, mask)]);
            await Future.delayed(Duration(milliseconds: 40 + _rng.nextInt(81)));
          }
          if (!_cancelled && _sessionId == session) engine.segColors([(r, g, b, mask)]);
        } catch (_) {}
      }
    }
    barLoop(0, 60, 255, _leftMask, 60); barLoop(160, 0, 255, _rightMask, 110);
  }

  void risties() {
    engine.turnOn(); engine.brightness(100);
    const keyframes = [
      (200, 90,  0),
      (255, 115, 75),
      (255,  85, 93),
    ];
    const cycleMs = 18000;
    final t0 = DateTime.now().millisecondsSinceEpoch;
    _loop(const Duration(milliseconds: 50), () {
      final t = ((DateTime.now().millisecondsSinceEpoch - t0) % cycleMs) / cycleMs;
      final seg = t * 3;
      final i = seg.floor() % 3;
      final frac = (1 - cos((seg - seg.floor()) * pi)) / 2;
      final c0 = keyframes[i];
      final c1 = keyframes[(i + 1) % 3];
      final r = (c0.$1 + (c1.$1 - c0.$1) * frac).round();
      final g = (c0.$2 + (c1.$2 - c0.$2) * frac).round();
      final b = (c0.$3 + (c1.$3 - c0.$3) * frac).round();
      engine.segColors([(r, g, b, _leftMask | _rightMask)]);
    });
  }

  void corpLab() {
    engine.turnOn(); engine.brightness(100);
    final t0 = DateTime.now().millisecondsSinceEpoch;
    _loop(const Duration(milliseconds: 50), () {
      final t = (DateTime.now().millisecondsSinceEpoch - t0) / 14000.0;
      final v = (1 - cos(2 * pi * t)) / 2 * 0.65;
      final r = (165 + 90 * v).round();
      final g = (195 - 110 * v).round();
      final b = (255 - 162 * v).round();
      engine.segColors([(r, g, b, _leftMask | _rightMask)]);
    });
  }

  void calmBlue() {
    engine.turnOn(); engine.brightness(100);
    _loop(const Duration(seconds: 3), () {
      engine.segColors([(165, 195, 255, _leftMask | _rightMask)]);
    });
  }

  void richDistrict() {
    engine.turnOn(); engine.brightness(100);
    final t0 = DateTime.now().millisecondsSinceEpoch;
    var nextFlickerMs = DateTime.now().millisecondsSinceEpoch + 20000 + _rng.nextInt(25001);
    var inFlicker = false;
    _loop(const Duration(milliseconds: 50), () {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (!inFlicker && now >= nextFlickerMs) {
        inFlicker = true;
        engine.segColors([(0, 0, 0, _leftMask | _rightMask)]);
        final cutMs = 200 + _rng.nextInt(301);
        Future.delayed(Duration(milliseconds: cutMs), () {
          inFlicker = false;
          nextFlickerMs = DateTime.now().millisecondsSinceEpoch + 20000 + _rng.nextInt(25001);
        });
      } else if (!inFlicker) {
        final t = (now - t0) / 12000.0;
        final v = (1 - cos(2 * pi * t)) / 2;
        final g2 = (80 * v).round();
        final b2 = (180 - 90 * v).round();
        engine.segColors([(255, g2, b2, _leftMask | _rightMask)]);
      }
    });
  }

  void draconis() {
    _stopLoop(); _cancelled = false;
    final session = _sessionId;
    engine.turnOn();
    Future<void> animation() async {
      await Future.delayed(const Duration(milliseconds: 50));
      if (_cancelled || _sessionId != session) return;
      while (!_cancelled && _sessionId == session) {
        try {
          engine.segColors([(80, 200, 10, _leftMask | _rightMask)]);
          await Future.delayed(const Duration(milliseconds: 100));
          if (_cancelled || _sessionId != session) break;
          engine.segColors([(13, 33, 1, _leftMask | _rightMask)]);
          await Future.delayed(const Duration(milliseconds: 180));
          if (_cancelled || _sessionId != session) break;
          engine.segColors([(60, 150, 7, _leftMask | _rightMask)]);
          await Future.delayed(const Duration(milliseconds: 100));
          if (_cancelled || _sessionId != session) break;
          engine.segColors([(13, 33, 1, _leftMask | _rightMask)]);
          await Future.delayed(Duration(milliseconds: 1400 + _rng.nextInt(401)));
        } catch (_) {}
      }
    }
    animation();
  }

  void autoDest() {
    engine.turnOn();
    var phase = 0.0;
    _loop(const Duration(milliseconds: 50), () {
      phase += pi / 18;
      final v = (sin(phase) + 1) / 2;
      final s = 0.05 + 0.95 * v;
      engine.segColors([((255 * s).round(), (80 * s).round(), 0, _leftMask | _rightMask)]);
    });
  }

  // ── Blackout Eve effects (ported from govee-scene-web/effect_defs.py) ──────

  void busStop() {
    engine.turnOn(); engine.brightness(100);
    final t0 = DateTime.now().millisecondsSinceEpoch;
    var nextSweep = t0 + 4000 + _rng.nextInt(4001);
    int? sweepStart;
    const sweepRise = 700, sweepHold = 150, sweepFall = 350;
    const sweepDuration = sweepRise + sweepHold + sweepFall;
    final shimmerPhase = List.generate(10, (_) => _rng.nextDouble() * 6.28);
    final neonLeft = _rng.nextBool();
    const neonBaseBlend = 0.22;
    var nextFlicker = t0 + 3000 + _rng.nextInt(3001);
    int? flickerStart;
    var flickerDuration = 0;
    var flickerStutters = 1;

    _loop(const Duration(milliseconds: 80), () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final t = (now - t0) / 1000.0;

      final base = List<List<int>>.generate(10, (i) {
        final shimmer = (sin(t * 0.9 + shimmerPhase[i]) + 1) / 2;
        final scale = 0.75 + 0.35 * shimmer;
        return [(55 * scale).round(), (70 * scale).round(), (100 * scale).round()];
      });

      double neonBlend;
      if (flickerStart == null && now >= nextFlicker) {
        flickerStart = now;
        flickerDuration = 120 + _rng.nextInt(231);
        flickerStutters = [1, 1, 1, 2, 3][_rng.nextInt(5)];
      }
      if (flickerStart != null) {
        final ft = now - flickerStart!;
        final cycle = flickerDuration * 2.2;
        if (ft >= cycle * flickerStutters) {
          flickerStart = null;
          nextFlicker = now + 3000 + _rng.nextInt(4001);
          neonBlend = neonBaseBlend;
        } else {
          neonBlend = (ft % cycle) < flickerDuration ? 0.55 : 0.10;
        }
      } else {
        neonBlend = neonBaseBlend;
      }

      final neonRange = neonLeft ? [0, 1, 2, 3, 4] : [5, 6, 7, 8, 9];
      for (final i in neonRange) {
        base[i][0] = (base[i][0] + (180 - base[i][0]) * neonBlend).round();
        base[i][1] = (base[i][1] + (15 - base[i][1]) * neonBlend).round();
        base[i][2] = (base[i][2] + (20 - base[i][2]) * neonBlend).round();
      }

      if (sweepStart == null && now >= nextSweep) {
        sweepStart = now;
      }
      if (sweepStart != null) {
        final st = now - sweepStart!;
        if (st >= sweepDuration) {
          sweepStart = null;
          nextSweep = now + 4000 + _rng.nextInt(4001);
        } else {
          double v;
          if (st < sweepRise) {
            v = pow(st / sweepRise, 2).toDouble();
          } else if (st < sweepRise + sweepHold) {
            v = 1.0;
          } else {
            v = max(0.0, 1.0 - (st - sweepRise - sweepHold) / sweepFall);
          }
          for (var i = 0; i < 10; i++) {
            base[i][0] = (base[i][0] + (255 - base[i][0]) * v).round();
            base[i][1] = (base[i][1] + (255 - base[i][1]) * v).round();
            base[i][2] = (base[i][2] + (240 - base[i][2]) * v).round();
          }
        }
      }

      engine.segColors([for (var i = 0; i < 10; i++) (base[i][0], base[i][1], base[i][2], 1 << i)]);
    });
  }

  void trial() {
    engine.turnOn();
    const r = 220, g = 230, b = 255;
    var phase = 0.0;
    var glitchUntil = 0;
    _loop(const Duration(milliseconds: 60), () {
      phase += 0.025;
      final v = (sin(phase) + 1) / 2;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now >= glitchUntil && _rng.nextDouble() < 0.015) {
        glitchUntil = now + 40 + _rng.nextInt(141);
      }
      double scale;
      if (now < glitchUntil) {
        scale = 0.85 + 0.15 * _rng.nextDouble();
      } else {
        scale = 0.20 + 0.35 * v;
      }
      engine.segColors([((r * scale).round(), (g * scale).round(), (b * scale).round(), _leftMask | _rightMask)]);
    });
  }

  void lyraApartment() {
    engine.turnOn(); engine.brightness(100);
    final t0 = DateTime.now().millisecondsSinceEpoch;
    const blue = (35, 55, 200);
    const pink = (210, 25, 145);
    final shimmerPhase = List.generate(10, (_) => _rng.nextDouble() * 6.28);
    var nextTwinkle = t0 + 3000 + _rng.nextInt(4001);
    int? twinkleSeg;
    int? twinkleStart;
    var twinkleDur = 0;

    _loop(const Duration(milliseconds: 80), () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final t = (now - t0) / 1000.0;

      final packet = List<List<int>>.generate(10, (_) => [0, 0, 0]);
      for (var h = 0; h < 5; h++) {
        final frac = h / 4.0;
        final baseR = blue.$1 + (pink.$1 - blue.$1) * frac;
        final baseG = blue.$2 + (pink.$2 - blue.$2) * frac;
        final baseB = blue.$3 + (pink.$3 - blue.$3) * frac;
        for (final i in [h, h + 5]) {
          final shimmer = (sin(t * 0.5 + shimmerPhase[i]) + 1) / 2;
          final scale = 0.7 + 0.3 * shimmer;
          packet[i] = [(baseR * scale).round(), (baseG * scale).round(), (baseB * scale).round()];
        }
      }

      if (twinkleSeg == null && now >= nextTwinkle) {
        twinkleSeg = _rng.nextInt(10);
        twinkleStart = now;
        twinkleDur = 150 + _rng.nextInt(201);
      }
      if (twinkleSeg != null) {
        final tt = now - twinkleStart!;
        if (tt >= twinkleDur) {
          twinkleSeg = null;
          nextTwinkle = now + 3000 + _rng.nextInt(4001);
        } else {
          final v = sin(pi * tt / twinkleDur);
          const warm = (255, 190, 90);
          final seg = packet[twinkleSeg!];
          packet[twinkleSeg!] = [
            (seg[0] + (warm.$1 - seg[0]) * v).round(),
            (seg[1] + (warm.$2 - seg[1]) * v).round(),
            (seg[2] + (warm.$3 - seg[2]) * v).round(),
          ];
        }
      }

      engine.segColors([for (var i = 0; i < 10; i++) (packet[i][0], packet[i][1], packet[i][2], 1 << i)]);
    });
  }

  void chase() {
    engine.turnOn(); engine.brightness(100);
    const off = (4, 3, 6);
    final t0 = DateTime.now().millisecondsSinceEpoch;
    var leftNext = t0;
    String? leftKind;
    var leftStart = 0;
    var leftDur = 0;
    var rightNext = t0 + 150;
    String? rightKind;
    var rightStart = 0;
    var rightDur = 0;

    (int, int, int) colorFor(String kind) {
      switch (kind) {
        case 'red':  return (255, 10, 5);
        case 'blue': return (10, 60, 255);
        default:     return (255, 250, 235); // white
      }
    }

    _loop(const Duration(milliseconds: 100), () {
      final now = DateTime.now().millisecondsSinceEpoch;

      var (lr, lg, lb) = off;
      if (leftKind == null && now >= leftNext) {
        final roll = _rng.nextDouble();
        leftKind = roll < 0.42 ? 'red' : (roll < 0.84 ? 'blue' : 'white');
        leftDur = leftKind == 'white' ? 100 + _rng.nextInt(61) : 120 + _rng.nextInt(81);
        leftStart = now;
        leftNext = now + 100 + _rng.nextInt(181);
      }
      if (leftKind != null) {
        if (now - leftStart >= leftDur) {
          leftKind = null;
        } else {
          (lr, lg, lb) = colorFor(leftKind!);
        }
      }

      var (rr, rg, rb) = off;
      if (rightKind == null && now >= rightNext) {
        final roll = _rng.nextDouble();
        rightKind = roll < 0.42 ? 'red' : (roll < 0.84 ? 'blue' : 'white');
        rightDur = rightKind == 'white' ? 100 + _rng.nextInt(61) : 120 + _rng.nextInt(81);
        rightStart = now;
        rightNext = now + 100 + _rng.nextInt(181);
      }
      if (rightKind != null) {
        if (now - rightStart >= rightDur) {
          rightKind = null;
        } else {
          (rr, rg, rb) = colorFor(rightKind!);
        }
      }

      engine.segColors([(lr, lg, lb, _leftMask), (rr, rg, rb, _rightMask)]);
    });
  }

  void meetingRoland() {
    engine.turnOn(); engine.brightness(100);
    const base = (42, 36, 85);
    const light = (255, 245, 210);
    const pulseRise = 180, pulseHold = 50, pulseFall = 320;
    const pulseDuration = pulseRise + pulseHold + pulseFall;

    final now0 = DateTime.now().millisecondsSinceEpoch;
    var active = true;
    var phaseEnd = now0 + 3000 + _rng.nextInt(3001);
    var nextPulse = now0;
    int? pulseStart;

    _loop(const Duration(milliseconds: 60), () {
      final now = DateTime.now().millisecondsSinceEpoch;

      if (now >= phaseEnd) {
        active = !active;
        if (active) {
          phaseEnd = now + 3000 + _rng.nextInt(3001);
          nextPulse = now;
        } else {
          phaseEnd = now + 2000 + _rng.nextInt(3001);
          pulseStart = null;
        }
      }

      var v = 0.0;
      if (active) {
        if (pulseStart == null && now >= nextPulse) {
          pulseStart = now;
        }
        if (pulseStart != null) {
          final pt = now - pulseStart!;
          if (pt >= pulseDuration) {
            pulseStart = null;
            nextPulse = now + 500 + _rng.nextInt(501);
          } else if (pt < pulseRise) {
            v = pt / pulseRise;
          } else if (pt < pulseRise + pulseHold) {
            v = 1.0;
          } else {
            v = max(0.0, 1.0 - (pt - pulseRise - pulseHold) / pulseFall);
          }
        }
      }

      final r = (base.$1 + (light.$1 - base.$1) * v).round();
      final g = (base.$2 + (light.$2 - base.$2) * v).round();
      final b = (base.$3 + (light.$3 - base.$3) * v).round();
      engine.segColors([(r, g, b, _leftMask | _rightMask)]);
    });
  }

  void happyJacks() {
    engine.turnOn(); engine.brightness(100);
    final t0 = DateTime.now().millisecondsSinceEpoch;

    const keyframes = [
      (200, 110, 20), (255, 180, 60), (255, 60, 30), (255, 90, 160),
    ];
    final leftCycle = 4500 + _rng.nextInt(1501);
    final rightCycle = 4500 + _rng.nextInt(1501);
    final leftPhase = _rng.nextDouble();
    final rightPhase = _rng.nextDouble();

    var nextFlash = t0 + 20000 + _rng.nextInt(15001);
    int? flashStart;
    String? flashSide;
    var flashCoinTimes = <int>[];
    const flashCoinDur = 90;
    var flashTotal = 0;

    List<int> breathe(int t, int cycle, double phase) {
      final tt = ((t / cycle) + phase) % 1.0;
      final seg = tt * keyframes.length;
      final i = seg.floor() % keyframes.length;
      final frac = (1 - cos((seg - seg.floor()) * pi)) / 2;
      final c0 = keyframes[i];
      final c1 = keyframes[(i + 1) % keyframes.length];
      return [
        (c0.$1 + (c1.$1 - c0.$1) * frac).round(),
        (c0.$2 + (c1.$2 - c0.$2) * frac).round(),
        (c0.$3 + (c1.$3 - c0.$3) * frac).round(),
      ];
    }

    _loop(const Duration(milliseconds: 80), () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final t = now - t0;

      final lc = breathe(t, leftCycle, leftPhase);
      final rc = breathe(t, rightCycle, rightPhase);

      if (flashStart == null && now >= nextFlash) {
        flashStart = now;
        flashSide = _rng.nextBool() ? 'left' : 'right';
        final nCoins = 4 + _rng.nextInt(2);
        var offset = 0;
        flashCoinTimes = [];
        for (var k = 0; k < nCoins; k++) {
          flashCoinTimes.add(offset);
          offset += 90 + _rng.nextInt(71);
        }
        flashTotal = offset + flashCoinDur;
      }
      if (flashStart != null) {
        final ft = now - flashStart!;
        if (ft >= flashTotal) {
          flashStart = null;
          nextFlash = now + 20000 + _rng.nextInt(15001);
        } else {
          var v = 0.0;
          for (final cTime in flashCoinTimes) {
            final dt = ft - cTime;
            if (dt >= 0 && dt < flashCoinDur) {
              v = max(v, sin(pi * dt / flashCoinDur));
            }
          }
          final target = flashSide == 'left' ? lc : rc;
          for (var k = 0; k < 3; k++) {
            target[k] = (target[k] + (255 - target[k]) * v).round();
          }
        }
      }

      engine.segColors([(lc[0], lc[1], lc[2], _leftMask), (rc[0], rc[1], rc[2], _rightMask)]);
    });
  }

  void setByRef(String ref) {
    _stopLoop();
    _currentRef = ref;
    switch (ref) {
      case 'police':    police();    break;
      case 'alarm':     alarm();     break;
      case 'club':      club();      break;
      case 'flicker':   flicker();   break;
      case 'disian':    disian();    break;
      case 'brave-sea': braveSea();  break;
      case 'torches':
      case 'torch-fire': torches();   break;
      case 'evil':      purpleEvil(); break;
      case 'flicker-slow': flickerSlow(); break;
      case 'flicker-pink':        flickerPink();        break;
      case 'neon-motel':          neonMotel();          break;
      case 'risties':             risties();            break;
      case 'corp-lab':            corpLab();            break;
      case 'calm-blue':           calmBlue();           break;
      case 'rich-district':       richDistrict();       break;
      case 'draconis':     draconis();    break;
      case 'autodestruct': autoDest();    break;
      case 'bus-stop':        busStop();       break;
      case 'trial':            trial();         break;
      case 'lyra-apartment':   lyraApartment(); break;
      case 'chase':            chase();         break;
      case 'meeting-roland':   meetingRoland(); break;
      case 'happy-jacks':      happyJacks();    break;
      case 'off':       stop();      break;
      default: engine.turnOn(); engine.color(200, 200, 200); engine.brightness(50);
    }
  }

  void dispose() => stop();
}

Future<LoadedPack?> extractPack(Uint8List zipBytes) async {
  final dir = await packStorageDir();
  final sessionDir = Directory('${dir.path}/session');
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
    return LoadedPack(pack: pack, zipBytes: zipBytes);
  }
  return null;
}

Future<Uint8List?> findStoredPackBytesBySha256(String targetSha256) async {
  try {
    final dir = await packStorageDir();
    final entities = await dir.list().toList();
    final files = entities.whereType<File>().where((f) => f.path.endsWith('.zip'));
    for (final file in files) {
      final bytes = await file.readAsBytes();
      final hash = sha256.convert(bytes).toString();
      if (hash == targetSha256) {
        return bytes;
      }
    }
  } catch (e) {
    debugPrint('findStoredPackBytesBySha256 error: $e');
  }
  return null;
}

String sanitizePackFilename(String packName) {
  final clean = packName.replaceAll(RegExp(r'[^\w\s\-]'), '_').trim();
  return clean.isEmpty ? 'session_pack' : clean;
}

Future<void> extractAndLoadSession(BuildContext context, Uint8List zipBytes, GoveeEngine engine) async {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(ApiResponseSnackBar(message: 'Extracting session pack…'));
  final loaded = await extractPack(zipBytes);
  if (!context.mounted) return;
  if (loaded != null) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => SessionOverviewScreen(loaded: loaded, engine: engine),
    ));
  } else {
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
      navigatorObservers: [routeObserver],
      home: const TheaterScreen(),
    );
  }
}

class TheaterScreen extends StatefulWidget {
  const TheaterScreen({super.key});
  @override
  State<TheaterScreen> createState() => _TheaterScreenState();
}

class _TheaterScreenState extends State<TheaterScreen>
    with WidgetsBindingObserver, RouteAware {
  final SpotifyService _spotify = SpotifyService.create();
  final _engine = GoveeEngine();
  late final SceneRunner _runner;
  bool _discovering = true;
  bool _found = false;
  bool _loginCancelled = false;

  Timer? _spotifyTimer;

  final SyncDiscovery _discovery = SyncDiscovery();
  StreamSubscription? _discoverySub;
  List<DiscoveredHost> _discoveredHosts = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _runner = SceneRunner(_engine);
    _doDiscover();
    _connectSpotify();
    _spotifyTimer = Timer.periodic(const Duration(minutes: 10), (_) => _refreshSpotify());

    _discoverySub = _discovery.hosts.listen((hosts) {
      if (mounted) setState(() => _discoveredHosts = hosts);
    });
    _startDiscovery();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    _stopDiscovery();
  }

  @override
  void didPopNext() {
    _startDiscovery();
  }

  void _startDiscovery() {
    _discovery.start();
  }

  void _stopDiscovery() {
    _discovery.stop();
  }

  Future<File> _lastIpFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/last_sync_ip.txt');
  }

  Future<String> _loadLastIp() async {
    try {
      final f = await _lastIpFile();
      if (await f.exists()) return (await f.readAsString()).trim();
    } catch (_) {}
    return '';
  }

  Future<void> _saveLastIp(String ip) async {
    try {
      final f = await _lastIpFile();
      await f.writeAsString(ip.trim());
    } catch (_) {}
  }

  Future<void> _joinHost(DiscoveredHost host) async {
    _stopDiscovery();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ClientLobbyScreen(
          discoveredHost: host,
        ),
      ),
    );
    if (mounted) _startDiscovery();
  }

  Future<void> _joinByIp() async {
    final lastIp = await _loadLastIp();
    if (!mounted) return;
    final controller = TextEditingController(text: lastIp);

    final ip = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Join by IP', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Host IP address',
            hintText: '192.168.1.50',
            labelStyle: TextStyle(color: Colors.grey),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF63B8DE)),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          FilledButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isNotEmpty) Navigator.pop(ctx, text);
            },
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF63B8DE)),
            child: const Text('Connect', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (ip != null && ip.isNotEmpty) {
      await _saveLastIp(ip);
      if (!mounted) return;
      _stopDiscovery();
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ClientLobbyScreen(
            hostAddress: InternetAddress(ip),
            port: kSyncPort,
          ),
        ),
      );
      if (mounted) _startDiscovery();
    }
  }

  void _connectSpotify() {
    _spotify.connect();
  }

  void _refreshSpotify() {
    _spotify.refresh();
  }

  Future<void> _loginSpotify() async {
    _loginCancelled = false;
    final ok = await _spotify.login();
    if (!ok && !_loginCancelled && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Spotify login failed — see the terminal log')),
      );
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _discoverySub?.cancel();
    _discovery.stop();
    _spotifyTimer?.cancel();
    _spotify.disconnect();
    WidgetsBinding.instance.removeObserver(this);
    _runner.dispose();
    _engine.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_found) _doDiscover();
      _connectSpotify();
    }
  }

  Future<void> _doDiscover() async {
    setState(() { _discovering = true; _found = false; });
    final ok = await _engine.discover();
    setState(() { _discovering = false; _found = ok; });
  }

  Future<void> _loadSession() async {
    try {
      final dir = await packStorageDir();
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
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              if (!Platform.isAndroid) _buildSpotifyRow(),
              const SizedBox(height: 24),
              if (_discovering) ...[
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 12),
                const Center(child: Text('Searching for light bar…', style: TextStyle(color: Colors.grey))),
              ] else ...[
                if (!_found) _buildLightsOfflineBanner(),
                Expanded(child: _buildSessionHome()),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSpotifyRow() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: AnimatedBuilder(
        animation: Listenable.merge([_spotify.connected, _spotify.loggingIn]),
        builder: (context, _) {
          final loggingIn = _spotify.loggingIn.value;
          final connected = _spotify.connected.value == true;

          if (loggingIn) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.grey),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Waiting for approval in browser…',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    _loginCancelled = true;
                    _spotify.cancelLogin();
                  },
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  child: const Text('Cancel'),
                ),
              ],
            );
          }

          if (connected) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle, color: Colors.greenAccent, size: 16),
                const SizedBox(width: 8),
                const Text(
                  'Spotify connected',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _loginSpotify,
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  child: const Text('Reconnect'),
                ),
              ],
            );
          }

          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.music_off, color: Colors.grey, size: 16),
              const SizedBox(width: 8),
              const Text(
                'Spotify not connected',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(width: 12),
              FilledButton.tonal(
                onPressed: _loginSpotify,
                style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                child: const Text('Connect Spotify'),
              ),
            ],
          );
        },
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
        GestureDetector(
          onTap: _doDiscover,
          child: Container(
            width: 10, height: 10,
            decoration: BoxDecoration(
              color: _found ? const Color(0xFF63B8DE) : Colors.redAccent.withAlpha(200),
              shape: BoxShape.circle,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLightsOfflineBanner() {
    return GestureDetector(
      onTap: _doDiscover,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white12),
        ),
        child: const Row(children: [
          Icon(Icons.wifi_off, color: Colors.grey, size: 16),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Lights not found — audio only mode',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
          Text('Retry', style: TextStyle(color: Color(0xFF63B8DE), fontSize: 12)),
        ]),
      ),
    );
  }

  Widget _buildNearbySessions() {
    if (_discoveredHosts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'No sessions on this network',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _joinByIp,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: const Color(0xFF63B8DE),
              ),
              child: const Text('Join by IP'),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'NEARBY SESSIONS',
                style: TextStyle(fontSize: 11, letterSpacing: 1.5, color: Colors.grey),
              ),
              TextButton(
                onPressed: _joinByIp,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: const Color(0xFF63B8DE),
                ),
                child: const Text('Join by IP', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ..._discoveredHosts.map((host) => Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF63B8DE).withAlpha(50)),
            ),
            child: Row(
              children: [
                const Icon(Icons.wifi_tethering, color: Color(0xFF63B8DE), size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${host.name} — ${host.packName.isNotEmpty ? host.packName : 'No pack'}',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => _joinHost(host),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF63B8DE),
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  child: const Text('Join', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          )),
        ],
      ),
    );
  }

  Widget _buildSessionHome() {
    return Column(
      children: [
        const Spacer(),
        _buildNearbySessions(),
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
    ('alarm',     'Alarm Rotation',  'Orange rotating beacon',  [Color(0xFF7a2800), Color(0xFF3a1000)], Color(0xFFFFAA44)),
    ('brave-sea', 'Brave Sea',      'High-action oceanic',     [Color(0xFF00021e), Color(0xFF001e3c)], Color(0xFF63B8DE)),
    ('torches',   'Torch Fire',      'Independent fire flickers', [Color(0xFF3a1000), Color(0xFF7a2800)], Color(0xFFFFAA44)),
    ('evil',      'Torch Fire Evil', 'Malevolent purple flames', [Color(0xFF1a0033), Color(0xFF660099)], Color(0xFFFF00FF)),
    ('club',      'Techno Club',     'Pink & green strobe',     [Color(0xFFCC006E), Color(0xFF00CC66)], Colors.white),
    ('flicker',   'Flickering',      'Damaged fluorescent',     [Color(0xFF3a3020), Color(0xFF1a1808)], Color(0xFFD4C080)),
    ('disian',       'Disian',       'Deep purple — metaplane',  [Color(0xFF1a0033), Color(0xFF330055)], Color(0xFFCCAAFF)),
    ('flicker-slow', 'Montero',      'Slow damaged lights',      [Color(0xFF3a3020), Color(0xFF1a1808)], Color(0xFFD4C080)),
    ('calm-blue',    'Calm Blue',    'Cold blue-white static',   [Color(0xFF102030), Color(0xFF203050)], Color(0xFFBBCCFF)),
    ('draconis',     'Draconis',     'Alien heartbeat',          [Color(0xFF102010), Color(0xFF1a3010)], Color(0xFF88DD22)),
    ('autodestruct', 'Autodestruct', 'Fast orange pulse',        [Color(0xFF3a1000), Color(0xFF7a2800)], Color(0xFFFF9933)),
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

class _StudioBrowserScreenState extends State<StudioBrowserScreen> with WidgetsBindingObserver {
  final _ipController = TextEditingController();
  List<Map<String, String>> _packs = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSavedIp();
  }

  @override
  void dispose() {
    _ipController.dispose();
    WidgetsBinding.instance.removeObserver(this);
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
      final saveDir = await packStorageDir();
      await File('${saveDir.path}/$filename').writeAsBytes(bytes);
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

class SessionOverviewScreen extends StatefulWidget {
  final LoadedPack loaded;
  final GoveeEngine engine;
  const SessionOverviewScreen({super.key, required this.loaded, required this.engine});

  SessionPack get pack => loaded.pack;

  @override
  State<SessionOverviewScreen> createState() => _SessionOverviewScreenState();
}

class _SessionOverviewScreenState extends State<SessionOverviewScreen> {
  SyncHost? _host;
  bool _hostBindFailed = false;

  @override
  void initState() {
    super.initState();
    _startHost();
  }

  Future<void> _startHost() async {
    final host = SyncHost(widget.loaded, SyncHost.defaultHostName());
    _host = host;
    bool ok = false;
    try {
      ok = await host.start();
    } catch (_) {}
    if (Platform.isAndroid) {
      try {
        await _wifiChannel.invokeMethod('startSessionService', {'title': widget.pack.name});
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _hostBindFailed = !ok;
    });
  }

  @override
  void dispose() {
    _host?.stop();
    if (Platform.isAndroid) {
      try {
        _wifiChannel.invokeMethod('stopSessionService').catchError((_) => null);
      } catch (_) {}
    }
    super.dispose();
  }

  Widget _buildHostSubtitle() {
    if (_hostBindFailed) {
      return const Text(
        'Could not host (port busy) — running solo',
        style: TextStyle(fontSize: 11, color: Colors.orangeAccent),
      );
    }
    if (_host == null) {
      return const Text(
        'Starting host…',
        style: TextStyle(fontSize: 11, color: Colors.white38),
      );
    }
    return ValueListenableBuilder<List<SyncDevice>>(
      valueListenable: _host!.devicesNotifier,
      builder: (context, devices, _) {
        final clients = devices.where((d) => !d.isHost).toList();
        final String text;
        if (clients.isEmpty) {
          text = 'Hosting · 0 devices connected';
        } else {
          final names = clients.map((c) => c.name).join(', ');
          text = 'Hosting · $names connected';
        }
        return Text(
          text,
          style: const TextStyle(fontSize: 11, color: Color(0xFF63B8DE)),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final pack = widget.pack;
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
            onTap: () {
              final controller = SessionController(pack);
              final renderer = SessionRenderer(
                controller,
                SceneRunner(widget.engine),
                AudioEngine(),
                SpotifyService.create(),
              );
              controller.enterScene(0);
              Navigator.push(context, MaterialPageRoute(
                builder: (_) => SessionPerformanceScreen(
                  controller: controller,
                  renderer: renderer,
                  host: _host,
                  hostName: _host != null && !_hostBindFailed
                      ? _host!.hostName
                      : SyncHost.defaultHostName(),
                ),
              ));
            },
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF0a1a2a), Color(0xFF051a2a)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF63B8DE).withAlpha(50)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.play_circle_outline, color: Color(0xFF63B8DE), size: 28),
                    const SizedBox(width: 12),
                    Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          pack.name,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        _buildHostSubtitle(),
                      ],
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
  final SessionControl controller;
  final SessionRenderer? renderer;
  final SyncHost? host;
  final String? hostName;

  const SessionPerformanceScreen({
    super.key,
    required this.controller,
    this.renderer,
    this.host,
    this.hostName,
  });

  bool get isRemote => renderer == null;

  @override
  State<SessionPerformanceScreen> createState() => _SessionPerformanceScreenState();
}

class _SessionPerformanceScreenState extends State<SessionPerformanceScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final SessionControl _controller;
  SessionRenderer? get _renderer => widget.renderer;
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = widget.controller;
    _controller.addListener(_onControllerChanged);
    _ticker = createTicker((_) {
      if (_controller.activeTriggers.isEmpty && _ticker.isTicking) {
        _ticker.stop();
      }
      setState(() {});
    });

    if (widget.host != null && _controller is SessionController) {
      widget.host!.attachController(_controller);
    }
  }

  void _onControllerChanged() {
    if (_controller.activeTriggers.isNotEmpty) {
      if (!_ticker.isTicking) _ticker.start();
    } else {
      if (_ticker.isTicking) _ticker.stop();
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _renderer?.onAppResumed();
    }
  }

  @override
  void dispose() {
    if (widget.host != null) {
      widget.host!.detachController();
    }
    _renderer?.dispose();
    _controller.removeListener(_onControllerChanged);
    if (!widget.isRemote) {
      _controller.dispose();
    }
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scene = _controller.scene;
    final int len = _controller.pack.scenes.length;
    final bool isCircular = len > 1;
    final int prevIndex = (_controller.sceneIndex - 1 + len) % len;
    final int nextIndex = (_controller.sceneIndex + 1) % len;
    final prev = isCircular ? _controller.pack.scenes[prevIndex] : null;
    final next = isCircular ? _controller.pack.scenes[nextIndex] : null;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
        const SingleActivator(LogicalKeyboardKey.space): () {
          HapticFeedback.mediumImpact();
          _controller.toggleStopAll();
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Column(
              children: [
                // Scene Nav
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        color: Colors.white54,
                        tooltip: 'Back to menu',
                        onPressed: () => Navigator.maybePop(context),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: prev != null ? () => _controller.enterScene(prevIndex) : null,
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
                        if (widget.hostName != null && widget.hostName!.isNotEmpty)
                          Text(
                            widget.isRemote
                                ? 'Remote · ${widget.hostName}'
                                : 'Host · ${widget.hostName}',
                            style: const TextStyle(fontSize: 10, color: Colors.grey),
                          ),
                      ])),
                      GestureDetector(
                        onTap: next != null ? () => _controller.enterScene(nextIndex) : null,
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
                    icon: Icon(_controller.isStopped ? Icons.play_arrow : Icons.stop, size: 32),
                    color: _controller.isStopped ? const Color(0xFF63B8DE) : Colors.white54,
                    tooltip: _controller.isStopped ? 'Resume scene' : 'Stop everything',
                    onPressed: () {
                      HapticFeedback.mediumImpact();
                      _controller.toggleStopAll();
                    },
                  ),
                ),
                const Divider(color: Colors.white12),
                // Trigger Grid
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.all(24),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 220,
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 16,
                      childAspectRatio: 1.8,
                    ),
                    itemCount: scene.triggers.length,
                    itemBuilder: (_, i) {
                      final t = scene.triggers[i];
                      final active = _controller.activeTriggers[i];
                      return Stack(
                        children: [
                          SizedBox.expand(
                            child: ElevatedButton(
                              onPressed: () {
                                HapticFeedback.lightImpact();
                                final err = _controller.fireTrigger(i);
                                if (err != null) {
                                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF1A1A1A),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: Text(t.name, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            ),
                          ),
                          if (active != null)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _TriggerBorderPainter(
                                    (DateTime.now().difference(active.startedAt).inMicroseconds /
                                            active.duration.inMicroseconds)
                                        .clamp(0.0, 1.0),
                                  ),
                                  child: const SizedBox.expand(),
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
                          _controller.spotifyPaused ? Icons.play_arrow : Icons.pause,
                          size: 20,
                        ),
                        color: _controller.spotifyPaused ? const Color(0xFF63B8DE) : Colors.grey,
                        onPressed: _controller.toggleSpotifyPause,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      const SizedBox(width: 12),
                      IconButton(
                        icon: const Icon(Icons.forward_10, size: 20),
                        color: Colors.grey,
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          _controller.seekSpotify(10000);
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      const SizedBox(width: 12),
                      IconButton(
                        icon: const Icon(Icons.skip_next, size: 20),
                        color: Colors.grey,
                        onPressed: _controller.skipSpotify,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      const SizedBox(width: 24),
                    ]),
                    Row(children: [
                      const Icon(Icons.waves, size: 18, color: Colors.grey),
                      Expanded(child: Slider(
                        value: _controller.ambientVolume, min: 0, max: 100, activeColor: const Color(0xFF63B8DE),
                        onChanged: (v) => _controller.setAmbientVolume(v),
                      )),
                      Text('${_controller.ambientVolume.round()}%', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(width: 44),
                    ]),
                    Row(children: [
                      const Icon(Icons.bolt, size: 18, color: Colors.grey),
                      Expanded(child: Slider(
                        value: _controller.triggerVolume, min: 0, max: 100, activeColor: const Color(0xFF63B8DE),
                        onChanged: (v) => _controller.setTriggerVolume(v),
                      )),
                      Text('${_controller.triggerVolume.round()}%', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(width: 44),
                    ]),
                  ]),
                ),
              ],
            ),
          ),
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
