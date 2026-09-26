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
  final int index;
  const TriggerFired(this.index);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'trigger_fired',
    'index': index,
  };

  factory TriggerFired.fromJson(Map<String, dynamic> json) =>
      TriggerFired(json['index'] as int);
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

  const ActiveTrigger({
    required this.startedAt,
    required this.duration,
  });
}

// ── Session Controller ───────────────────────────────────────────────────────

class SessionController extends ChangeNotifier {
  final SessionPack pack;

  int sceneIndex = 0;
  bool isStopped = false;
  bool spotifyPaused = false;
  double ambientVolume = 50.0;
  double triggerVolume = 80.0;

  final Map<int, ActiveTrigger> activeTriggers = {};
  final Map<int, Timer> _triggerTimers = {};
  final StreamController<SessionEvent> _events = StreamController<SessionEvent>.broadcast();

  SessionController(this.pack);

  SessionScene get scene => pack.scenes[sceneIndex];
  Stream<SessionEvent> get events => _events.stream;

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

  String? fireTrigger(int index) {
    if (index < 0 || index >= scene.triggers.length) return null;
    final t = scene.triggers[index];
    if (t.soundId.isEmpty) {
      if (t.flashRef != null) {
        notifyListeners();
        _events.add(TriggerFired(index));
        return null;
      } else {
        return 'No sound or light assigned to this trigger';
      }
    }
    final asset = pack.audioManifest[t.soundId];
    if (asset == null) {
      return 'Sound not found: ${t.soundId}';
    }

    final durationMs = asset.durationMs > 0 ? asset.durationMs : 5000;
    final duration = Duration(milliseconds: durationMs);

    _triggerTimers[index]?.cancel();
    activeTriggers[index] = ActiveTrigger(
      startedAt: DateTime.now(),
      duration: duration,
    );
    _triggerTimers[index] = Timer(duration, () {
      _triggerTimers.remove(index);
      activeTriggers.remove(index);
      notifyListeners();
    });

    notifyListeners();
    _events.add(TriggerFired(index));
    return null;
  }

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

  void toggleSpotifyPause() {
    spotifyPaused = !spotifyPaused;
    notifyListeners();
    _events.add(SpotifyPauseToggled(spotifyPaused));
  }

  void seekSpotify(int deltaMs) {
    notifyListeners();
    _events.add(SpotifySeekRelative(deltaMs));
  }

  void skipSpotify() {
    notifyListeners();
    _events.add(const SpotifySkipped());
  }

  void setAmbientVolume(double percent) {
    ambientVolume = percent;
    notifyListeners();
    _events.add(AmbientVolumeChanged(percent));
  }

  void setTriggerVolume(double percent) {
    triggerVolume = percent;
    notifyListeners();
    _events.add(TriggerVolumeChanged(percent));
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
