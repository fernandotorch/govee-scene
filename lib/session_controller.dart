import 'dart:async';

import 'package:flutter/foundation.dart';

import 'session_model.dart';

// ── Events ───────────────────────────────────────────────────────────────────

sealed class SessionEvent {
  const SessionEvent();

  Map<String, dynamic> toJson();

  static SessionEvent fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    switch (type) {
      case 'scene_entered':
        return SceneEntered.fromJson(json);
      case 'trigger_fired':
        return TriggerFired.fromJson(json);
      case 'stopped_all':
        return StoppedAll.fromJson(json);
      case 'resumed_all':
        return ResumedAll.fromJson(json);
      case 'spotify_pause_toggled':
        return SpotifyPauseToggled.fromJson(json);
      case 'spotify_seek_relative':
        return SpotifySeekRelative.fromJson(json);
      case 'spotify_skipped':
        return SpotifySkipped.fromJson(json);
      case 'ambient_volume_changed':
        return AmbientVolumeChanged.fromJson(json);
      case 'trigger_volume_changed':
        return TriggerVolumeChanged.fromJson(json);
      default:
        throw ArgumentError('Unknown event type: $type');
    }
  }
}

class SceneEntered extends SessionEvent {
  final int index;
  const SceneEntered(this.index);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'scene_entered',
    'index': index,
  };

  factory SceneEntered.fromJson(Map<String, dynamic> json) =>
      SceneEntered(json['index'] as int);
}

class TriggerFired extends SessionEvent {
  final int sceneIndex;
  final int index;
  final int playId;
  const TriggerFired({
    required this.sceneIndex,
    required this.index,
    this.playId = -1,
  });

  @override
  Map<String, dynamic> toJson() => {
    'type': 'trigger_fired',
    'sceneIndex': sceneIndex,
    'index': index,
    'playId': playId,
  };

  factory TriggerFired.fromJson(Map<String, dynamic> json) =>
      TriggerFired(
        sceneIndex: json['sceneIndex'] as int? ?? 0,
        index: json['index'] as int,
        playId: json['playId'] as int? ?? -1,
      );
}

class StoppedAll extends SessionEvent {
  const StoppedAll();

  @override
  Map<String, dynamic> toJson() => {
    'type': 'stopped_all',
  };

  factory StoppedAll.fromJson(Map<String, dynamic> json) => const StoppedAll();
}

class ResumedAll extends SessionEvent {
  const ResumedAll();

  @override
  Map<String, dynamic> toJson() => {
    'type': 'resumed_all',
  };

  factory ResumedAll.fromJson(Map<String, dynamic> json) => const ResumedAll();
}

class SpotifyPauseToggled extends SessionEvent {
  final bool paused;
  const SpotifyPauseToggled(this.paused);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'spotify_pause_toggled',
    'paused': paused,
  };

  factory SpotifyPauseToggled.fromJson(Map<String, dynamic> json) =>
      SpotifyPauseToggled(json['paused'] as bool);
}

class SpotifySeekRelative extends SessionEvent {
  final int deltaMs;
  const SpotifySeekRelative(this.deltaMs);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'spotify_seek_relative',
    'deltaMs': deltaMs,
  };

  factory SpotifySeekRelative.fromJson(Map<String, dynamic> json) =>
      SpotifySeekRelative(json['deltaMs'] as int);
}

class SpotifySkipped extends SessionEvent {
  const SpotifySkipped();

  @override
  Map<String, dynamic> toJson() => {
    'type': 'spotify_skipped',
  };

  factory SpotifySkipped.fromJson(Map<String, dynamic> json) => const SpotifySkipped();
}

class AmbientVolumeChanged extends SessionEvent {
  final double percent;
  const AmbientVolumeChanged(this.percent);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'ambient_volume_changed',
    'percent': percent,
  };

  factory AmbientVolumeChanged.fromJson(Map<String, dynamic> json) =>
      AmbientVolumeChanged((json['percent'] as num).toDouble());
}

class TriggerVolumeChanged extends SessionEvent {
  final double percent;
  const TriggerVolumeChanged(this.percent);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'trigger_volume_changed',
    'percent': percent,
  };

  factory TriggerVolumeChanged.fromJson(Map<String, dynamic> json) =>
      TriggerVolumeChanged((json['percent'] as num).toDouble());
}

// ── Active Trigger ───────────────────────────────────────────────────────────

class ActiveTrigger {
  final DateTime startedAt;
  final Duration duration;
  final int playId;

  const ActiveTrigger({
    required this.startedAt,
    required this.duration,
    this.playId = -1,
  });
}

abstract class SessionControl extends ChangeNotifier {
  SessionPack get pack;
  SessionScene get scene;
  int get sceneIndex;
  bool get isStopped;
  bool get spotifyPaused;
  double get ambientVolume;
  double get triggerVolume;
  Map<int, ActiveTrigger> get activeTriggers;

  void enterScene(int index);
  String? fireTrigger(int index);
  void toggleStopAll();
  void toggleSpotifyPause();
  void seekSpotify(int deltaMs);
  void skipSpotify();
  void setAmbientVolume(double percent);
  void setTriggerVolume(double percent);
}

// ── Session Controller ───────────────────────────────────────────────────────

class SessionController extends SessionControl {
  @override
  final SessionPack pack;

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

  @override
  final Map<int, ActiveTrigger> activeTriggers = {};
  final Map<int, Timer> _triggerTimers = {};
  final StreamController<SessionEvent> _events = StreamController<SessionEvent>.broadcast();
  int _nextPlayId = 1;

  SessionController(this.pack);

  @override
  SessionScene get scene => pack.scenes[sceneIndex];
  Stream<SessionEvent> get events => _events.stream;

  @override
  void enterScene(int index) {
    sceneIndex = index;
    ambientVolume = scene.ambientVolume.toDouble();
    isStopped = false;
    if (scene.spotify.uri.isNotEmpty) {
      spotifyPaused = false;
    }
    notifyListeners();
    _events.add(SceneEntered(index));
  }

  @override
  String? fireTrigger(int index) {
    if (index < 0 || index >= scene.triggers.length) return null;
    final t = scene.triggers[index];
    if (t.soundId.isEmpty) {
      if (t.flashRef != null) {
        notifyListeners();
        _events.add(TriggerFired(sceneIndex: sceneIndex, index: index, playId: -1));
        return null;
      } else {
        return 'No sound or light assigned to this trigger';
      }
    }
    final asset = pack.audioManifest[t.soundId];
    if (asset == null) {
      return 'Sound not found: ${t.soundId}';
    }

    final playId = _nextPlayId++;
    final durationMs = asset.durationMs > 0 ? asset.durationMs : 5000;
    final duration = Duration(milliseconds: durationMs);

    _triggerTimers[index]?.cancel();
    activeTriggers[index] = ActiveTrigger(
      startedAt: DateTime.now(),
      duration: duration,
      playId: playId,
    );
    _triggerTimers[index] = Timer(duration, () {
      _triggerTimers.remove(index);
      activeTriggers.remove(index);
      notifyListeners();
    });

    notifyListeners();
    _events.add(TriggerFired(sceneIndex: sceneIndex, index: index, playId: playId));
    return null;
  }

  void updateTriggerDuration(int playId, Duration real) {
    if (playId < 0) return;
    int? targetIndex;
    ActiveTrigger? targetTrigger;
    for (final entry in activeTriggers.entries) {
      if (entry.value.playId == playId) {
        targetIndex = entry.key;
        targetTrigger = entry.value;
        break;
      }
    }
    if (targetIndex == null || targetTrigger == null) return;

    _triggerTimers[targetIndex]?.cancel();
    final remaining = targetTrigger.startedAt.add(real).difference(DateTime.now());
    if (remaining <= Duration.zero) {
      _triggerTimers.remove(targetIndex);
      activeTriggers.remove(targetIndex);
    } else {
      activeTriggers[targetIndex] = ActiveTrigger(
        startedAt: targetTrigger.startedAt,
        duration: real,
        playId: playId,
      );
      _triggerTimers[targetIndex] = Timer(remaining, () {
        _triggerTimers.remove(targetIndex);
        activeTriggers.remove(targetIndex);
        notifyListeners();
      });
    }
    notifyListeners();
  }

  void endTrigger(int playId) {
    if (playId < 0) return;
    int? targetIndex;
    for (final entry in activeTriggers.entries) {
      if (entry.value.playId == playId) {
        targetIndex = entry.key;
        break;
      }
    }
    if (targetIndex == null) return;

    _triggerTimers.remove(targetIndex)?.cancel();
    activeTriggers.remove(targetIndex);
    notifyListeners();
  }

  @override
  void toggleStopAll() {
    isStopped = !isStopped;
    if (isStopped) {
      spotifyPaused = true;
      for (final timer in _triggerTimers.values) {
        timer.cancel();
      }
      _triggerTimers.clear();
      activeTriggers.clear();
      notifyListeners();
      _events.add(const StoppedAll());
    } else {
      if (scene.spotify.uri.isNotEmpty) {
        spotifyPaused = false;
      }
      notifyListeners();
      _events.add(const ResumedAll());
    }
  }

  @override
  void toggleSpotifyPause() {
    spotifyPaused = !spotifyPaused;
    notifyListeners();
    _events.add(SpotifyPauseToggled(spotifyPaused));
  }

  @override
  void seekSpotify(int deltaMs) {
    notifyListeners();
    _events.add(SpotifySeekRelative(deltaMs));
  }

  @override
  void skipSpotify() {
    notifyListeners();
    _events.add(const SpotifySkipped());
  }

  @override
  void setAmbientVolume(double percent) {
    ambientVolume = percent;
    notifyListeners();
    _events.add(AmbientVolumeChanged(percent));
  }

  @override
  void setTriggerVolume(double percent) {
    triggerVolume = percent;
    notifyListeners();
    _events.add(TriggerVolumeChanged(percent));
  }

  Map<String, dynamic> toSnapshot() {
    final now = DateTime.now();
    return {
      'sceneIndex': sceneIndex,
      'isStopped': isStopped,
      'spotifyPaused': spotifyPaused,
      'ambientVolume': ambientVolume.round(),
      'triggerVolume': triggerVolume.round(),
      'activeTriggers': activeTriggers.entries.map((e) {
        final elapsed = now.difference(e.value.startedAt).inMilliseconds;
        return {
          'index': e.key,
          'elapsedMs': elapsed < 0 ? 0 : elapsed,
          'durationMs': e.value.duration.inMilliseconds,
        };
      }).toList(),
    };
  }

  @override
  void dispose() {
    for (final timer in _triggerTimers.values) {
      timer.cancel();
    }
    _triggerTimers.clear();
    activeTriggers.clear();
    _events.close();
    super.dispose();
  }
}
