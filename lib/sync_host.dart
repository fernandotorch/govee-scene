import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'session_controller.dart';
import 'session_model.dart';
import 'sync_protocol.dart';

const _wifiChannel = MethodChannel('com.feru.govee_scene/wifi');

class _ConnectedClient {
  final WebSocket socket;
  final InternetAddress? remoteAddress;
  String deviceId = '';
  String deviceName = '';
  StreamSubscription? subscription;

  _ConnectedClient({
    required this.socket,
    required this.remoteAddress,
  });
}

class SyncHost {
  final LoadedPack loaded;
  final String hostName;
  final int port;

  HttpServer? _httpServer;
  RawDatagramSocket? _udpSocket;
  SessionController? _controller;

  final List<_ConnectedClient> _clients = [];
  final ValueNotifier<List<SyncDevice>> devicesNotifier =
      ValueNotifier<List<SyncDevice>>([]);

  DateTime? _lastSnapshotSentAt;
  Timer? _coalesceTimer;
  bool _hasPendingSnapshot = false;

  SyncHost(this.loaded, this.hostName, {this.port = kSyncPort}) {
    devicesNotifier.value = _buildDeviceList();
  }

  int get actualPort => _httpServer?.port ?? port;

  static String defaultHostName() {
    final h = Platform.localHostname.trim();
    if (h.isEmpty || h == 'localhost') {
      return Platform.isAndroid ? 'Android phone' : 'Computer';
    }
    return h;
  }

  List<SyncDevice> _buildDeviceList() {
    return [
      SyncDevice(id: 'host', name: hostName, isHost: true),
      ..._clients.map(
        (c) => SyncDevice(id: c.deviceId, name: c.deviceName, isHost: false),
      ),
    ];
  }

  @visibleForTesting
  List<WebSocket> get clientSockets => _clients.map((c) => c.socket).toList();

  Future<void> _acquireMulticastLock() async {
    if (Platform.isAndroid) {
      try {
        await _wifiChannel.invokeMethod('acquireMulticastLock');
      } catch (e) {
        debugPrint('Multicast lock acquire error: $e');
      }
    }
  }

  Future<void> _releaseMulticastLock() async {
    if (Platform.isAndroid) {
      try {
        await _wifiChannel.invokeMethod('releaseMulticastLock');
      } catch (e) {
        debugPrint('Multicast lock release error: $e');
      }
    }
  }

  Future<bool> start() async {
    try {
      await _acquireMulticastLock();

      _httpServer = await HttpServer.bind(
        InternetAddress.anyIPv4,
        port,
        shared: false,
      );

      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        kDiscoveryPort,
        reuseAddress: true,
      );

      _udpSocket!.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = _udpSocket?.receive();
          if (dg != null) {
            final text = utf8.decode(dg.data, allowMalformed: true).trim();
            if (text == kDiscoveryProbe) {
              final reply = utf8.encode(SyncProtocol.discoveryReply(
                name: hostName,
                port: actualPort,
                protocol: kProtocolVersion,
                pack: loaded.pack.name,
              ));
              _udpSocket?.send(reply, dg.address, dg.port);
            }
          }
        }
      });

      _httpServer!.listen(_handleHttpRequest);
      return true;
    } catch (e) {
      debugPrint('SyncHost start failed: $e');
      await stop();
      return false;
    }
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    final path = request.uri.path;

    if (request.method == 'GET' && path == '/sync') {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        try {
          final socket = await WebSocketTransformer.upgrade(request);
          _handleClient(socket, request.connectionInfo?.remoteAddress);
        } catch (e) {
          request.response.statusCode = HttpStatus.badRequest;
          await request.response.close();
        }
      } else {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
      }
      return;
    }

    if (request.method == 'GET' && path.startsWith('/pack/')) {
      final expectedPath = '/pack/${loaded.id}.zip';
      if (path == expectedPath) {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType('application', 'zip');
        request.response.headers.contentLength = loaded.zipBytes.length;
        request.response.add(loaded.zipBytes);
        await request.response.close();
        return;
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  void _handleClient(WebSocket socket, InternetAddress? remoteAddress) {
    socket.pingInterval = const Duration(seconds: 3);
    final client = _ConnectedClient(socket: socket, remoteAddress: remoteAddress);
    bool welcomed = false;

    client.subscription = socket.listen(
      (data) {
        try {
          if (data is! String) return;
          final msg = SyncProtocol.parseMessage(data);
          if (msg == null) return;
          final type = msg['type'] as String?;

          if (!welcomed) {
            if (type != 'hello') {
              socket.add(SyncProtocol.reject(reason: 'Expected hello'));
              socket.close();
              return;
            }
            final protocol = msg['protocol'] as int? ?? 0;
            if (protocol != kProtocolVersion) {
              socket.add(SyncProtocol.reject(
                reason: 'Different app version — update both devices',
              ));
              socket.close();
              return;
            }
            client.deviceId = msg['deviceId'] as String? ?? '';
            client.deviceName = msg['deviceName'] as String? ?? 'Client';
            welcomed = true;
            _clients.add(client);

            socket.add(SyncProtocol.welcome(
              hostName: hostName,
              protocol: kProtocolVersion,
              pack: SyncPackInfo(id: loaded.id, name: loaded.pack.name),
              phase: _controller != null ? 'session' : 'lobby',
              state: _controller?.toSnapshot(),
            ));

            devicesNotifier.value = _buildDeviceList();
            _broadcastLobby();
            return;
          }

          if (type == 'command') {
            final rawName = msg['name'];
            final name = rawName is String ? rawName : null;
            final rawArgs = msg['args'];
            final args = rawArgs is Map<String, dynamic>
                ? rawArgs
                : const <String, dynamic>{};
            _handleCommand(name, args);
          }
        } catch (e) {
          debugPrint('SyncHost error processing client message: $e');
        }
      },
      onDone: () {
        if (_clients.remove(client)) {
          devicesNotifier.value = _buildDeviceList();
          _broadcastLobby();
        }
      },
      onError: (err) {
        if (_clients.remove(client)) {
          devicesNotifier.value = _buildDeviceList();
          _broadcastLobby();
        }
      },
      cancelOnError: true,
    );
  }

  void _handleCommand(String? name, Map<String, dynamic> args) {
    try {
      final c = _controller;
      if (c == null || name == null) return;

      switch (name) {
        case 'enterScene':
          final index = args['index'] as int?;
          if (index != null && index >= 0 && index < c.pack.scenes.length) {
            c.enterScene(index);
          }
          break;
        case 'fireTrigger':
          final sceneIndex = args['sceneIndex'] as int?;
          final index = args['index'] as int?;
          if (sceneIndex != null &&
              index != null &&
              sceneIndex == c.sceneIndex &&
              index >= 0 &&
              index < c.scene.triggers.length) {
            c.fireTrigger(index);
          }
          break;
        case 'toggleStopAll':
          c.toggleStopAll();
          break;
        case 'toggleSpotifyPause':
          c.toggleSpotifyPause();
          break;
        case 'seekSpotify':
          final deltaMs = args['deltaMs'] as int?;
          if (deltaMs != null) c.seekSpotify(deltaMs);
          break;
        case 'skipSpotify':
          c.skipSpotify();
          break;
        case 'setAmbientVolume':
          final percent = args['percent'] as num?;
          if (percent != null) c.setAmbientVolume(percent.toDouble());
          break;
        case 'setTriggerVolume':
          final percent = args['percent'] as num?;
          if (percent != null) c.setTriggerVolume(percent.toDouble());
          break;
      }
    } catch (e) {
      debugPrint('SyncHost error handling command: $e');
    }
  }

  void _broadcast(String message) {
    for (final client in List.of(_clients)) {
      try {
        client.socket.add(message);
      } catch (_) {}
    }
  }

  void _broadcastLobby() {
    _broadcast(SyncProtocol.lobby(devices: devicesNotifier.value));
  }

  void _sendStateSnapshot() {
    final c = _controller;
    if (c == null) return;
    _broadcast(SyncProtocol.state(state: c.toSnapshot()));
    _lastSnapshotSentAt = DateTime.now();
    _hasPendingSnapshot = false;
  }

  void _onControllerChanged() {
    final c = _controller;
    if (c == null) return;

    final now = DateTime.now();
    final last = _lastSnapshotSentAt;

    if (last == null || now.difference(last).inMilliseconds >= 50) {
      _coalesceTimer?.cancel();
      _coalesceTimer = null;
      _sendStateSnapshot();
    } else {
      _hasPendingSnapshot = true;
      if (_coalesceTimer == null) {
        final remainingMs = 50 - now.difference(last).inMilliseconds;
        _coalesceTimer = Timer(Duration(milliseconds: remainingMs.clamp(1, 50)), () {
          _coalesceTimer = null;
          if (_hasPendingSnapshot) {
            _sendStateSnapshot();
          }
        });
      }
    }
  }

  void attachController(SessionController c) {
    _controller = c;
    _broadcast(SyncProtocol.sessionStarted(state: c.toSnapshot()));
    c.addListener(_onControllerChanged);
  }

  void detachController() {
    _coalesceTimer?.cancel();
    _coalesceTimer = null;
    _hasPendingSnapshot = false;
    _controller?.removeListener(_onControllerChanged);
    _controller = null;
    _broadcast(SyncProtocol.sessionEnded());
  }

  Future<void> stop() async {
    _coalesceTimer?.cancel();
    _coalesceTimer = null;
    _hasPendingSnapshot = false;
    _controller?.removeListener(_onControllerChanged);
    _controller = null;

    for (final client in List.of(_clients)) {
      try {
        await client.subscription?.cancel();
        await client.socket.close();
      } catch (_) {}
    }
    _clients.clear();
    devicesNotifier.value = [];

    try {
      await _httpServer?.close(force: true);
    } catch (_) {}
    _httpServer = null;

    try {
      _udpSocket?.close();
    } catch (_) {}
    _udpSocket = null;

    await _releaseMulticastLock();
  }
}
