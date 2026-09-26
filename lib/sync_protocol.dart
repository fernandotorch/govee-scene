import 'dart:convert';
import 'dart:typed_data';

const int kSyncPort = 47810;
const int kDiscoveryPort = 47811;
const int kProtocolVersion = 1;
const String kDiscoveryProbe = 'GOVEE_SCENE_DISCOVER';

/// Information about a pack transmitted in welcome messages.
class SyncPackInfo {
  final String id;
  final String name;

  const SyncPackInfo({required this.id, required this.name});

  factory SyncPackInfo.fromJson(Map<String, dynamic> json) => SyncPackInfo(
        id: json['id'] as String,
        name: json['name'] as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
      };
}

/// Information sent from host to client on connection.
class SyncWelcome {
  final String hostName;
  final int protocol;
  final SyncPackInfo? pack;
  final String phase; // "lobby" | "session"
  final Map<String, dynamic>? state;

  const SyncWelcome({
    required this.hostName,
    required this.protocol,
    this.pack,
    required this.phase,
    this.state,
  });

  factory SyncWelcome.fromJson(Map<String, dynamic> json) => SyncWelcome(
        hostName: json['hostName'] as String? ?? 'Host',
        protocol: json['protocol'] as int? ?? 1,
        pack: json['pack'] != null
            ? SyncPackInfo.fromJson(json['pack'] as Map<String, dynamic>)
            : null,
        phase: json['phase'] as String? ?? 'lobby',
        state: json['state'] as Map<String, dynamic>?,
      );

  Map<String, dynamic> toJson() => {
        'type': 'welcome',
        'hostName': hostName,
        'protocol': protocol,
        'pack': pack?.toJson(),
        'phase': phase,
        'state': state,
      };
}

/// Representation of a device in the lobby.
class SyncDevice {
  final String id;
  final String name;
  final bool isHost;

  const SyncDevice({
    required this.id,
    required this.name,
    required this.isHost,
  });

  factory SyncDevice.fromJson(Map<String, dynamic> json) => SyncDevice(
        id: json['id'] as String,
        name: json['name'] as String,
        isHost: json['isHost'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'isHost': isHost,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncDevice &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          isHost == other.isHost;

  @override
  int get hashCode => Object.hash(id, name, isHost);
}

/// Snapshot of an active trigger for synchronization.
class ActiveTriggerSnapshot {
  final int index;
  final int elapsedMs;
  final int durationMs;

  const ActiveTriggerSnapshot({
    required this.index,
    required this.elapsedMs,
    required this.durationMs,
  });

  factory ActiveTriggerSnapshot.fromJson(Map<String, dynamic> json) =>
      ActiveTriggerSnapshot(
        index: (json['index'] as num).toInt(),
        elapsedMs: (json['elapsedMs'] as num).toInt(),
        durationMs: (json['durationMs'] as num).toInt(),
      );

  Map<String, dynamic> toJson() => {
        'index': index,
        'elapsedMs': elapsedMs,
        'durationMs': durationMs,
      };
}

/// Helper functions to encode and decode protocol messages.
class SyncProtocol {
  // Client -> Host message factories
  static String hello({
    required String deviceId,
    required String deviceName,
    int protocol = kProtocolVersion,
  }) =>
      jsonEncode({
        'type': 'hello',
        'deviceId': deviceId,
        'deviceName': deviceName,
        'protocol': protocol,
      });

  static String command({
    required String name,
    required Map<String, dynamic> args,
  }) =>
      jsonEncode({
        'type': 'command',
        'name': name,
        'args': args,
      });

  // Host -> Client message factories
  static String welcome({
    required String hostName,
    int protocol = kProtocolVersion,
    SyncPackInfo? pack,
    required String phase, // "lobby" | "session"
    Map<String, dynamic>? state,
  }) =>
      jsonEncode({
        'type': 'welcome',
        'hostName': hostName,
        'protocol': protocol,
        'pack': pack?.toJson(),
        'phase': phase,
        'state': state,
      });

  static String reject({required String reason}) => jsonEncode({
        'type': 'reject',
        'reason': reason,
      });

  static String lobby({required List<SyncDevice> devices}) => jsonEncode({
        'type': 'lobby',
        'devices': devices.map((d) => d.toJson()).toList(),
      });

  static String sessionStarted({required Map<String, dynamic> state}) =>
      jsonEncode({
        'type': 'sessionStarted',
        'state': state,
      });

  static String state({required Map<String, dynamic> state}) => jsonEncode({
        'type': 'state',
        'state': state,
      });

  static String sessionEnded() => jsonEncode({
        'type': 'sessionEnded',
      });

  // UDP Discovery helpers
  static Uint8List discoveryProbeBytes() =>
      Uint8List.fromList(utf8.encode(kDiscoveryProbe));

  static String discoveryReply({
    required String name,
    int port = kSyncPort,
    int protocol = kProtocolVersion,
    String pack = '',
  }) =>
      jsonEncode({
        'name': name,
        'port': port,
        'protocol': protocol,
        'pack': pack,
      });

  static Map<String, dynamic>? parseMessage(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}
    return null;
  }
}
