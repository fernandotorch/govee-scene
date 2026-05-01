import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

// H6047: 10 segments — 0-4 left bar, 5-9 right bar.
const _leftMask  = 0x01F;
const _rightMask = 0x3E0;

// ── UDP engine ────────────────────────────────────────────────────────────────

const _wifiChannel = MethodChannel('com.feru.govee_scene/wifi');

class GoveeEngine {
  InternetAddress? _deviceIp;
  RawDatagramSocket? _socket;

  Future<bool> discover() async {
    try {
      await _wifiChannel.invokeMethod('acquireMulticastLock');

      final recv = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _listenPort);
      final send = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);

      final msg = jsonEncode({'msg': {'cmd': 'scan', 'data': {'account_topic': 'reserve'}}});
      send.send(utf8.encode(msg), InternetAddress(_multicastIp), _discoveryPort);

      final completer = Completer<bool>();
      Timer(const Duration(seconds: 5), () {
        if (!completer.isCompleted) {
          recv.close();
          send.close();
          completer.complete(false);
        }
      });

      recv.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = recv.receive();
          if (dg != null && !completer.isCompleted) {
            _deviceIp = dg.address;
            _initSocket().then((_) {
              recv.close();
              send.close();
              completer.complete(true);
            });
          }
        }
      });

      final result = await completer.future;
      await _wifiChannel.invokeMethod('releaseMulticastLock');
      return result;
    } catch (_) {
      await _wifiChannel.invokeMethod('releaseMulticastLock').catchError((_) {});
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
    pkt[0] = 0x33;
    pkt[1] = 0x05;
    pkt[2] = 0x15;
    pkt[3] = 0x01;
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
  final _rng = Random();

  SceneRunner(this.engine);

  void _stopLoop() {
    _cancelled = true;
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

  void _loopVariable(Duration Function() onFn, Duration Function()? offFn) {
    _stopLoop();
    _cancelled = false;
    void tick(bool isOn) {
      final delay = isOn ? onFn() : (offFn?.call() ?? Duration.zero);
      _timer = Timer(delay, () => tick(offFn != null ? !isOn : true));
    }
    tick(true);
  }

  void police() {
    engine.turnOn();
    engine.brightness(100);
    var phase = false;
    _loop(const Duration(milliseconds: 250), () {
      phase
        ? engine.segColors([(0, 40, 255, _leftMask), (255, 0, 0, _rightMask)])
        : engine.segColors([(255, 0, 0, _leftMask), (0, 40, 255, _rightMask)]);
      phase = !phase;
    });
  }

  void alarm() {
    engine.turnOn();
    engine.brightness(100);
    var phase = false;
    _loop(const Duration(milliseconds: 250), () {
      phase
        ? engine.segColors([(10, 2, 0, _leftMask),  (255, 55, 0, _rightMask)])
        : engine.segColors([(255, 55, 0, _leftMask), (10, 2, 0, _rightMask)]);
      phase = !phase;
    });
  }

  void flicker() {
    _stopLoop();
    _cancelled = false;
    engine.turnOn();
    engine.segColors([(240, 230, 200, _leftMask), (240, 230, 200, _rightMask)]);

    Future<void> barLoop(int mask) async {
      while (!_cancelled) {
        engine.segColors([(240, 230, 200, mask)]);
        await Future.delayed(Duration(milliseconds: 3000 + _rng.nextInt(2001)));
        if (_cancelled) break;

        var remaining = 500 + _rng.nextInt(1501);
        while (remaining > 0 && !_cancelled) {
          final cut = min(remaining, 80 + _rng.nextInt(421));
          engine.segColors([(2, 2, 2, mask)]);
          await Future.delayed(Duration(milliseconds: cut));
          remaining -= cut;
          if (_cancelled || remaining <= 0) break;
          engine.segColors([(240, 230, 200, mask)]);
          await Future.delayed(Duration(milliseconds: 40 + _rng.nextInt(81)));
        }

        if (!_cancelled) engine.segColors([(240, 230, 200, mask)]);
      }
    }

    barLoop(_leftMask);
    barLoop(_rightMask);
  }

  void club() {
    final palette = [
      (255, 0, 140), (255, 0, 140),
      (0, 255, 100), (0, 255, 100),
      (160, 0, 255), (0, 200, 255),
    ];
    engine.turnOn();
    _loopVariable(() {
      if (_rng.nextDouble() < 0.07) {
        engine.color(255, 255, 255);
        engine.brightness(100);
        return const Duration(milliseconds: 40);
      }
      final (r, g, b) = palette[_rng.nextInt(palette.length)];
      engine.color(r, g, b);
      engine.brightness(55 + _rng.nextInt(45));
      return Duration(milliseconds: 60 + _rng.nextInt(220));
    }, null);
  }

  void disian() {
    engine.turnOn();
    var phase = 0.0;
    _loop(const Duration(milliseconds: 50), () {
      phase += 0.04;
      final v = (sin(phase) + 1) / 2;
      if (_rng.nextDouble() < 0.015) {
        engine.color(200, 210, 255);
        engine.brightness(85);
        return;
      }
      engine.color((65 + v * 45).round(), 0, (105 + v * 95).round());
      engine.brightness((22 + v * 58).round());
    });
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
  String _activeScene = '';

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

  void _trigger(String name, VoidCallback fn) {
    setState(() => _activeScene = name);
    fn();
  }

  @override
  void dispose() {
    _runner.dispose();
    _engine.dispose();
    super.dispose();
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
              const SizedBox(height: 24),
              if (_discovering) ...[
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 12),
                const Center(child: Text('Searching for light bar…', style: TextStyle(color: Colors.grey))),
              ] else if (!_found)
                Expanded(child: _buildNotFound())
              else
                Expanded(child: _buildSceneList()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('GOVEE LIGHT THEATER', style: TextStyle(fontSize: 11, color: Colors.grey, letterSpacing: 1.5)),
              SizedBox(height: 4),
              Text('Session Control', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        if (_found)
          GestureDetector(
            onTap: _doDiscover,
            child: Container(
              width: 10, height: 10,
              decoration: const BoxDecoration(color: Colors.greenAccent, shape: BoxShape.circle),
            ),
          ),
      ],
    );
  }

  Widget _buildNotFound() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.wifi_off, color: Colors.grey, size: 48),
          const SizedBox(height: 16),
          const Text('Light bar not found', style: TextStyle(fontSize: 18)),
          const SizedBox(height: 8),
          const Text(
            'Enable LAN Control in the Govee app\nand join the same Wi-Fi network.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 24),
          ElevatedButton(onPressed: _doDiscover, child: const Text('Try again')),
        ],
      ),
    );
  }

  Widget _buildSceneList() {
    final scenes = [
      _SceneDef('off',     'Off',               'Kill all effects',          [const Color(0xFF2a2a2a), const Color(0xFF1a1a1a)], Colors.grey,                 () => _trigger('off',     _runner.stop)),
      _SceneDef('police',  'Police Siren',       'Red / blue rotating',       [const Color(0xFFCC0000), const Color(0xFF0033DD)], Colors.white,                () => _trigger('police',  _runner.police)),
      _SceneDef('alarm',   'Emergency Alarm',    'Orange rotating beacon',    [const Color(0xFF7a2800), const Color(0xFF3a1000)], const Color(0xFFFFAA44),     () => _trigger('alarm',   _runner.alarm)),
      _SceneDef('club',    'Techno Club',        'Pink & green strobe',       [const Color(0xFFCC006E), const Color(0xFF00CC66)], Colors.white,                () => _trigger('club',    _runner.club)),
      _SceneDef('flicker', 'Flickering Light',   'Damaged fluorescent',       [const Color(0xFF3a3020), const Color(0xFF1a1808)], const Color(0xFFD4C080),     () => _trigger('flicker', _runner.flicker)),
      _SceneDef('disian',  'Disian Encounter',   'Deep purple — metaplane',   [const Color(0xFF1a0033), const Color(0xFF330055)], const Color(0xFFCCAAFF),     () => _trigger('disian',  _runner.disian)),
    ];

    return ListView.separated(
      itemCount: scenes.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) => _SceneButton(scene: scenes[i], active: _activeScene == scenes[i].id),
    );
  }
}

// ── Scene button ──────────────────────────────────────────────────────────────

class _SceneDef {
  final String id, label, sub;
  final List<Color> gradient;
  final Color textColor;
  final VoidCallback action;
  const _SceneDef(this.id, this.label, this.sub, this.gradient, this.textColor, this.action);
}

class _SceneButton extends StatelessWidget {
  final _SceneDef scene;
  final bool active;
  const _SceneButton({super.key, required this.scene, required this.active});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: scene.action,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: scene.gradient, begin: Alignment.centerLeft, end: Alignment.centerRight),
          borderRadius: BorderRadius.circular(14),
          border: active ? Border.all(color: Colors.white38, width: 1.5) : null,
          boxShadow: active
            ? [BoxShadow(color: scene.gradient.last.withAlpha(100), blurRadius: 12, spreadRadius: 1)]
            : null,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(scene.label, style: TextStyle(color: scene.textColor, fontWeight: FontWeight.bold, fontSize: 17)),
                  const SizedBox(height: 3),
                  Text(scene.sub, style: TextStyle(color: scene.textColor.withAlpha(160), fontSize: 13)),
                ],
              ),
            ),
            if (active) Icon(Icons.radio_button_checked, color: scene.textColor.withAlpha(180), size: 18),
          ],
        ),
      ),
    );
  }
}
