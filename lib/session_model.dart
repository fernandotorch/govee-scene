import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class LoadedPack {
  final SessionPack pack;
  final Uint8List zipBytes;
  final String id;

  LoadedPack({
    required this.pack,
    required this.zipBytes,
    String? id,
  }) : id = id ?? sha256.convert(zipBytes).toString();
}

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
  final int startTime;
  SpotifyConfig({required this.uri, required this.volume, this.startTime = 0});
  factory SpotifyConfig.fromJson(Map<String, dynamic> json) =>
      SpotifyConfig(
        uri: json['uri'] ?? '',
        volume: json['volume'] ?? 50,
        startTime: json['start_time'] ?? 0,
      );
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
