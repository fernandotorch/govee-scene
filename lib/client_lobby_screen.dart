import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'main.dart';
import 'session_model.dart';
import 'sync_client.dart';
import 'sync_protocol.dart';

class ClientLobbyScreen extends StatefulWidget {
  final DiscoveredHost? discoveredHost;
  final InternetAddress? hostAddress;
  final int port;
  final String? initialHostName;

  const ClientLobbyScreen({
    super.key,
    this.discoveredHost,
    this.hostAddress,
    this.port = kSyncPort,
    this.initialHostName,
  });

  @override
  State<ClientLobbyScreen> createState() => _ClientLobbyScreenState();
}

class _ClientLobbyScreenState extends State<ClientLobbyScreen> {
  late final SyncClient _client;
  LoadedPack? _loadedPack;
  bool _connecting = true;
  bool _downloading = false;
  double _downloadProgress = 0.0;
  bool _inSession = false;
  Map<String, dynamic>? _pendingSessionState;
  RemoteSessionController? _remoteController;

  StreamSubscription? _welcomeSub;
  StreamSubscription? _rejectSub;
  StreamSubscription? _sessionStartedSub;
  StreamSubscription? _sessionEndedSub;

  @override
  void initState() {
    super.initState();
    _client = SyncClient();
    _client.onLost = _onHostLost;

    _welcomeSub = _client.welcomeStream.listen(_onWelcome);
    _rejectSub = _client.rejectStream.listen(_onReject);
    _sessionStartedSub = _client.sessionStartedStream.listen(_onSessionStarted);
    _sessionEndedSub = _client.sessionEndedStream.listen(_onSessionEnded);

    _initConnect();
  }

  Future<void> _initConnect() async {
    try {
      final target = widget.discoveredHost ?? widget.hostAddress!;
      await _client.connect(target, port: widget.port);
      if (!mounted) return;
      setState(() {
        _connecting = false;
      });
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not connect to host: $e')),
      );
    }
  }

  void _onHostLost() {
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Host lost — session ended on this device'),
      ),
    );
  }

  void _onReject(String reason) {
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(reason)),
    );
  }

  void _onWelcome(SyncWelcome welcome) async {
    final packInfo = welcome.pack;
    if (packInfo == null) return;

    // Check if stored locally by SHA-256
    final existingBytes = await findStoredPackBytesBySha256(packInfo.id);
    Uint8List zipBytes;
    if (existingBytes != null) {
      zipBytes = existingBytes;
    } else {
      if (!mounted) return;
      setState(() {
        _downloading = true;
        _downloadProgress = 0.0;
      });
      try {
        zipBytes = await _client.downloadPack(
          packInfo.id,
          onProgress: (p) {
            if (mounted) {
              setState(() => _downloadProgress = p);
            }
          },
        );
        // Save to packStorageDir() as <sanitised pack name>.zip
        final dir = await packStorageDir();
        final filename = '${sanitizePackFilename(packInfo.name)}.zip';
        final file = File('${dir.path}/$filename');
        await file.writeAsBytes(zipBytes);
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _downloading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to download pack: $e')),
        );
        return;
      }
    }

    if (!mounted) return;
    final loaded = await extractPack(zipBytes);
    if (!mounted) return;
    setState(() {
      _downloading = false;
      _loadedPack = loaded;
    });

    if ((welcome.phase == 'session' || _pendingSessionState != null) &&
        !_inSession) {
      final stateToUse = welcome.phase == 'session'
          ? (welcome.state ?? _pendingSessionState)
          : _pendingSessionState;
      _enterPerformance(stateToUse);
    }
  }

  void _onSessionStarted(Map<String, dynamic> state) {
    if (_loadedPack != null) {
      if (!_inSession) {
        _enterPerformance(state);
      }
    } else {
      _pendingSessionState = state;
    }
  }

  void _onSessionEnded(void _) {
    if (_inSession) {
      Navigator.maybePop(context);
    }
  }

  Future<void> _enterPerformance(Map<String, dynamic>? state) async {
    if (_inSession || _loadedPack == null || !mounted) return;
    _inSession = true;
    _pendingSessionState = null;

    final controller = RemoteSessionController(
      pack: _loadedPack!.pack,
      client: _client,
      initialState: state,
    );
    _remoteController = controller;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SessionPerformanceScreen(
          controller: controller,
          renderer: null,
          hostName: _client.hostName,
        ),
      ),
    );

    _inSession = false;
    _remoteController?.dispose();
    _remoteController = null;
  }

  @override
  void dispose() {
    _welcomeSub?.cancel();
    _rejectSub?.cancel();
    _sessionStartedSub?.cancel();
    _sessionEndedSub?.cancel();
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hostName = widget.initialHostName ??
        widget.discoveredHost?.name ??
        _client.hostName;
    final packName = _loadedPack?.pack.name ??
        _client.lastWelcome?.pack?.name ??
        widget.discoveredHost?.packName ??
        '';

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        leading: IconButton(
          icon: const Icon(Icons.close, size: 20),
          onPressed: () {
            _client.close();
            Navigator.maybePop(context);
          },
        ),
        title: Text(
          hostName,
          style: const TextStyle(fontSize: 16, letterSpacing: 0.5),
        ),
      ),
      body: _connecting
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Color(0xFF63B8DE)),
                  SizedBox(height: 16),
                  Text('Connecting to host…', style: TextStyle(color: Colors.grey)),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Container(
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
                      Row(
                        children: [
                          const Icon(
                            Icons.wifi_tethering,
                            color: Color(0xFF63B8DE),
                            size: 28,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              packName.isNotEmpty ? packName : 'Waiting for pack…',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_downloading) ...[
                        Text(
                          'Receiving pack… ${(_downloadProgress * 100).toInt()}%',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF63B8DE),
                          ),
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: _downloadProgress > 0 ? _downloadProgress : null,
                            backgroundColor: Colors.white12,
                            color: const Color(0xFF63B8DE),
                          ),
                        ),
                      ] else ...[
                        Text(
                          'Connected to $hostName · waiting for host to start',
                          style: const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                  child: Text(
                    'CONNECTED DEVICES',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.5,
                      color: Colors.grey,
                    ),
                  ),
                ),
                ValueListenableBuilder<List<SyncDevice>>(
                  valueListenable: _client.devices,
                  builder: (context, devices, _) {
                    if (devices.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          'Waiting for device list…',
                          style: TextStyle(color: Colors.grey, fontSize: 13),
                        ),
                      );
                    }
                    return Column(
                      children: devices.map((d) {
                        final isSelf = d.id == _client.deviceId;
                        String label = d.name;
                        if (d.isHost) {
                          label += ' (Host)';
                        } else if (isSelf) {
                          label += ' (You)';
                        }

                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1A1A1A),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: d.isHost
                                  ? const Color(0xFF63B8DE).withAlpha(80)
                                  : Colors.white12,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                d.isHost
                                    ? Icons.stars_rounded
                                    : Icons.phone_android,
                                color: d.isHost
                                    ? const Color(0xFF63B8DE)
                                    : Colors.grey,
                                size: 20,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  label,
                                  style: TextStyle(
                                    fontWeight: d.isHost
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
              ],
            ),
    );
  }
}
