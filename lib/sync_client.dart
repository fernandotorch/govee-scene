import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'session_controller.dart';
import 'session_model.dart';
import 'sync_protocol.dart';

/// Represents a host discovered on the LAN.
class DiscoveredHost {
  final InternetAddress address;
  final int port;
  final String name;
  final String packName;

  DiscoveredHost({
    required this.address,
    required this.port,
    required this.name,
    required this.packName,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiscoveredHost &&
          runtimeType == other.runtimeType &&
          address.address == other.address.address &&
          port == other.port;

  @override
  int get hashCode => Object.hash(address.address, port);
}

/// Discovers SyncHosts on the LAN via UDP broadcasts.
class SyncDiscovery {
  RawDatagramSocket? _socket;
  Timer? _timer;
  bool _active = false;

  final Map<String, ({DiscoveredHost host, DateTime lastSeen})> _discovered = {};
  final StreamController<List<DiscoveredHost>> _hostsController =
      StreamController<List<DiscoveredHost>>.broadcast();

  List<DiscoveredHost> _currentHosts = [];
  List<DiscoveredHost> get currentHosts => List.unmodifiable(_currentHosts);
  Stream<List<DiscoveredHost>> get hosts => _hostsController.stream;

  Set<String> _localAddresses = {};

  Future<void> _updateLocalAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      _localAddresses = interfaces
          .expand((iface) => iface.addresses)
          .map((a) => a.address)
          .toSet();
    } catch (_) {}
  }

  Future<void> start() async {
    if (_active) return;
    _active = true;
    _discovered.clear();
    _emitList();

    await _updateLocalAddresses();

    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _socket?.broadcastEnabled = true;

      _socket?.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = _socket?.receive();
          if (dg != null) {
            _handleDatagram(dg);
          }
        }
      });
    } catch (e) {
      debugPrint('SyncDiscovery socket bind error: $e');
    }

    _sendProbes();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      _pruneStale();
      _sendProbes();
    });
  }

  void _handleDatagram(Datagram dg) {
    if (dg.address.isLoopback || _localAddresses.contains(dg.address.address)) {
      return;
    }

    try {
      final text = utf8.decode(dg.data, allowMalformed: true);
      final map = jsonDecode(text);
      if (map is Map<String, dynamic>) {
        final name = map['name'] as String? ?? 'Host';
        final port = map['port'] as int? ?? kSyncPort;
        final pack = map['pack'] as String? ?? '';
        final key = '${dg.address.address}:$port';

        final host = DiscoveredHost(
          address: dg.address,
          port: port,
          name: name,
          packName: pack,
        );
        _discovered[key] = (host: host, lastSeen: DateTime.now());
        _emitList();
      }
    } catch (_) {}
  }

  Future<void> _sendProbes() async {
    if (!_active || _socket == null) return;
    final probe = SyncProtocol.discoveryProbeBytes();

    // 1. Universal broadcast
    try {
      _socket?.send(probe, InternetAddress('255.255.255.255'), kDiscoveryPort);
    } catch (_) {}

    // 2. Directed broadcasts for non-loopback IPv4 interfaces
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            final bcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
            try {
              _socket?.send(probe, InternetAddress(bcast), kDiscoveryPort);
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  void _pruneStale() {
    final now = DateTime.now();
    final expired = <String>[];
    for (final entry in _discovered.entries) {
      if (now.difference(entry.value.lastSeen).inSeconds >= 6) {
        expired.add(entry.key);
      }
    }
    if (expired.isNotEmpty) {
      for (final k in expired) {
        _discovered.remove(k);
      }
      _emitList();
    }
  }

  void _emitList() {
    _currentHosts = _discovered.values.map((v) => v.host).toList();
    _hostsController.add(_currentHosts);
  }

  Future<void> stop() async {
    _active = false;
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
    _discovered.clear();
    _emitList();
  }
}

/// Client managing WebSocket connection to a SyncHost.
class SyncClient {
  final String deviceId;
  final String deviceName;

  WebSocket? _socket;
  InternetAddress? hostAddress;
  int hostPort = kSyncPort;

  SyncWelcome? lastWelcome;
  final ValueNotifier<List<SyncDevice>> devices =
      ValueNotifier<List<SyncDevice>>([]);

  final StreamController<SyncWelcome> _welcomeController =
      StreamController<SyncWelcome>.broadcast();
  final StreamController<Map<String, dynamic>> _sessionStartedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<Map<String, dynamic>> _stateController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<void> _sessionEndedController =
      StreamController<void>.broadcast();
  final StreamController<String> _rejectController =
      StreamController<String>.broadcast();

  Stream<SyncWelcome> get welcomeStream => _welcomeController.stream;
  Stream<Map<String, dynamic>> get sessionStartedStream =>
      _sessionStartedController.stream;
  Stream<Map<String, dynamic>> get stateStream => _stateController.stream;
  Stream<void> get sessionEndedStream => _sessionEndedController.stream;
  Stream<String> get rejectStream => _rejectController.stream;

  VoidCallback? onLost;
  bool _closing = false;
  bool _lostFired = false;

  SyncClient({String? deviceId, String? deviceName})
      : deviceId = deviceId ??
            'device_${DateTime.now().microsecondsSinceEpoch}',
        deviceName = deviceName ?? _defaultDeviceName();

  static String _defaultDeviceName() {
    final h = Platform.localHostname.trim();
    if (h.isEmpty || h == 'localhost') {
      return Platform.isAndroid ? 'Android phone' : 'Computer';
    }
    return h;
  }

  String get hostName => lastWelcome?.hostName ?? 'Host';

  @visibleForTesting
  WebSocket? get socket => _socket;

  Future<void> connect(dynamic host, {int port = kSyncPort}) async {
    _closing = false;
    _lostFired = false;

    if (host is DiscoveredHost) {
      hostAddress = host.address;
      hostPort = host.port;
    } else if (host is InternetAddress) {
      hostAddress = host;
      hostPort = port;
    } else if (host is String) {
      hostAddress = InternetAddress(host);
      hostPort = port;
    } else {
      throw ArgumentError('Invalid host: $host');
    }

    final wsUri = 'ws://${hostAddress!.address}:$hostPort/sync';
    _socket = await WebSocket.connect(wsUri).timeout(const Duration(seconds: 5));
    _socket!.pingInterval = const Duration(seconds: 3);

    _socket!.add(SyncProtocol.hello(
      deviceId: deviceId,
      deviceName: deviceName,
      protocol: kProtocolVersion,
    ));

    _socket!.listen(
      _handleIncomingMessage,
      onDone: _notifyLost,
      onError: (_) => _notifyLost(),
      cancelOnError: true,
    );
  }

  void _handleIncomingMessage(dynamic data) {
    if (data is! String) return;
    final msg = SyncProtocol.parseMessage(data);
    if (msg == null) return;
    final type = msg['type'] as String?;

    switch (type) {
      case 'welcome':
        final welcome = SyncWelcome.fromJson(msg);
        lastWelcome = welcome;
        _welcomeController.add(welcome);
        if (welcome.state != null) {
          _stateController.add(welcome.state!);
        }
        break;
      case 'reject':
        final reason = msg['reason'] as String? ?? 'Rejected by host';
        _rejectController.add(reason);
        break;
      case 'lobby':
        final rawList = msg['devices'] as List<dynamic>? ?? [];
        devices.value = rawList
            .map((d) => SyncDevice.fromJson(d as Map<String, dynamic>))
            .toList();
        break;
      case 'sessionStarted':
        final state = msg['state'] as Map<String, dynamic>? ?? {};
        _sessionStartedController.add(state);
        break;
      case 'state':
        final state = msg['state'] as Map<String, dynamic>? ?? {};
        _stateController.add(state);
        break;
      case 'sessionEnded':
        _sessionEndedController.add(null);
        break;
    }
  }

  void _notifyLost() {
    if (!_closing && !_lostFired) {
      _lostFired = true;
      onLost?.call();
    }
  }

  void sendCommand(String name, Map<String, dynamic> args) {
    if (_closing || _socket == null) return;
    try {
      _socket?.add(SyncProtocol.command(name: name, args: args));
    } catch (_) {}
  }

  Future<Uint8List> downloadPack(
    String id, {
    void Function(double progress)? onProgress,
  }) async {
    final client = HttpClient();
    try {
      final url =
          Uri.parse('http://${hostAddress!.address}:$hostPort/pack/$id.zip');
      final request = await client.getUrl(url);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Failed to download pack: HTTP ${response.statusCode}',
        );
      }

      final totalBytes = response.contentLength;
      var received = 0;
      final chunks = <List<int>>[];
      await for (final chunk in response) {
        chunks.add(chunk);
        received += chunk.length;
        if (totalBytes > 0 && onProgress != null) {
          onProgress(received / totalBytes);
        }
      }
      return Uint8List.fromList(chunks.expand((c) => c).toList());
    } finally {
      client.close();
    }
  }

  Future<void> close() async {
    _closing = true;
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
  }
}

/// Remote control implementation of SessionControl driving a session over LAN.
class RemoteSessionController extends SessionControl {
  @override
  final SessionPack pack;
  final SyncClient client;

  @override
  int sceneIndex = 0;
  @override
  bool isStopped = false;
  @override
  bool spotifyPaused = false;
  @override
  double ambientVolume = 50.0;
  @override
  double triggerVolume = 80.0;

  DateTime? _ambientLocalUntil;
  DateTime? _triggerLocalUntil;

  @override
  Map<int, ActiveTrigger> activeTriggers = {};
  final Map<int, Timer> _triggerTimers = {};

  StreamSubscription? _stateSub;
  StreamSubscription? _sessionStartedSub;

  RemoteSessionController({
    required this.pack,
    required this.client,
    Map<String, dynamic>? initialState,
  }) {
    if (initialState != null) {
      applySnapshot(initialState);
    }
    _stateSub = client.stateStream.listen(applySnapshot);
    _sessionStartedSub = client.sessionStartedStream.listen(applySnapshot);
  }

  @override
  SessionScene get scene => pack.scenes[sceneIndex];

  void applySnapshot(Map<String, dynamic> data) {
    if (data.containsKey('sceneIndex')) {
      sceneIndex = (data['sceneIndex'] as num).toInt();
    }
    if (data.containsKey('isStopped')) {
      isStopped = data['isStopped'] as bool;
    }
    if (data.containsKey('spotifyPaused')) {
      spotifyPaused = data['spotifyPaused'] as bool;
    }

    final now = DateTime.now();
    if (_ambientLocalUntil == null || !now.isBefore(_ambientLocalUntil!)) {
      if (data.containsKey('ambientVolume')) {
        ambientVolume = (data['ambientVolume'] as num).toDouble();
      }
    }
    if (_triggerLocalUntil == null || !now.isBefore(_triggerLocalUntil!)) {
      if (data.containsKey('triggerVolume')) {
        triggerVolume = (data['triggerVolume'] as num).toDouble();
      }
    }

    final rawTriggers = data['activeTriggers'] as List<dynamic>?;
    for (final t in _triggerTimers.values) {
      t.cancel();
    }
    _triggerTimers.clear();

    final newActive = <int, ActiveTrigger>{};
    if (rawTriggers != null) {
      for (final item in rawTriggers) {
        if (item is Map<String, dynamic>) {
          final index = (item['index'] as num).toInt();
          final elapsedMs = (item['elapsedMs'] as num).toInt();
          final durationMs = (item['durationMs'] as num).toInt();
          final duration = Duration(milliseconds: durationMs);
          final startedAt = now.subtract(Duration(milliseconds: elapsedMs));
          newActive[index] = ActiveTrigger(startedAt: startedAt, duration: duration);

          final remaining = duration - Duration(milliseconds: elapsedMs);
          if (remaining > Duration.zero) {
            _triggerTimers[index] = Timer(remaining, () {
              _triggerTimers.remove(index);
              activeTriggers.remove(index);
              notifyListeners();
            });
          }
        }
      }
    }
    activeTriggers = newActive;
    notifyListeners();
  }

  @override
  void enterScene(int index) {
    client.sendCommand('enterScene', {'index': index});
  }

  @override
  String? fireTrigger(int index) {
    if (index < 0 || index >= scene.triggers.length) return null;
    final t = scene.triggers[index];
    if (t.soundId.isEmpty) {
      if (t.flashRef != null) {
        client.sendCommand('fireTrigger', {
          'sceneIndex': sceneIndex,
          'index': index,
        });
        return null;
      } else {
        return 'No sound or light assigned to this trigger';
      }
    }
    final asset = pack.audioManifest[t.soundId];
    if (asset == null) {
      return 'Sound not found: ${t.soundId}';
    }

    client.sendCommand('fireTrigger', {
      'sceneIndex': sceneIndex,
      'index': index,
    });
    return null;
  }

  @override
  void toggleStopAll() {
    client.sendCommand('toggleStopAll', {});
  }

  @override
  void toggleSpotifyPause() {
    client.sendCommand('toggleSpotifyPause', {});
  }

  @override
  void seekSpotify(int deltaMs) {
    client.sendCommand('seekSpotify', {'deltaMs': deltaMs});
  }

  @override
  void skipSpotify() {
    client.sendCommand('skipSpotify', {});
  }

  @override
  void setAmbientVolume(double percent) {
    ambientVolume = percent;
    _ambientLocalUntil = DateTime.now().add(const Duration(milliseconds: 400));
    notifyListeners();
    client.sendCommand('setAmbientVolume', {'percent': percent});
  }

  @override
  void setTriggerVolume(double percent) {
    triggerVolume = percent;
    _triggerLocalUntil = DateTime.now().add(const Duration(milliseconds: 400));
    notifyListeners();
    client.sendCommand('setTriggerVolume', {'percent': percent});
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _sessionStartedSub?.cancel();
    for (final t in _triggerTimers.values) {
      t.cancel();
    }
    _triggerTimers.clear();
    super.dispose();
  }
}
