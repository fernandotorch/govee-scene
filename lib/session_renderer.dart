import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import 'main.dart';
import 'session_controller.dart';
import 'session_model.dart';
import 'spotify_service.dart';

class SessionRenderer {
  final SessionController controller;
  final SceneRunner runner;
  final AudioEngine audio;
  final SpotifyService spotify;

  bool lightsEnabled = true;
  bool soundEnabled = true;

  late final StreamSubscription<SessionEvent> _subscription;
  bool _disposed = false;

  SessionRenderer(this.controller, this.runner, this.audio, this.spotify) {
    _subscription = controller.events.listen(_onEvent);
  }

  void _onEvent(SessionEvent event) {
    switch (event) {
      case SceneEntered(:final index):
        _onSceneEntered(index);
      case TriggerFired(:final sceneIndex, :final index):
        if (sceneIndex == controller.sceneIndex) {
          _onTriggerFired(index);
        }
      case StoppedAll():
        _onStoppedAll();
      case ResumedAll():
        _onResumedAll();
      case SpotifyPauseToggled(:final paused):
        _onSpotifyPauseToggled(paused);
      case SpotifySeekRelative(:final deltaMs):
        _onSpotifySeekRelative(deltaMs);
      case SpotifySkipped():
        _onSpotifySkipped();
      case AmbientVolumeChanged(:final percent):
        _onAmbientVolumeChanged(percent);
      case TriggerVolumeChanged(:final percent):
        _onTriggerVolumeChanged(percent);
    }
  }

  int _currentRampId = 0;

  Future<void> _rampAmbient(double from, double to, {int steps = 6, int stepMs = 30}) async {
    final rampId = ++_currentRampId;
    for (int i = 1; i <= steps; i++) {
      if (_disposed) return;
      if (rampId != _currentRampId) return;
      final v = from + (to - from) * i / steps;
      audio.setAmbientVolume(v);
      if (i < steps) await Future.delayed(Duration(milliseconds: stepMs));
    }
  }

  // How far the bed drops while a trigger is playing. 0.35 = -9 dB.
  static const double _ambientDuckFactor = 0.35;

  // Number of triggers currently holding the duck open.
  int _activeDucks = 0;
  int _duckGeneration = 0;

  void _duckAmbientFor(AudioPlayer player, int assetDurationMs) {
    final gen = _duckGeneration;
    _activeDucks++;
    if (_activeDucks == 1) spotify.duckStart();
    // Cancel any ramp in flight (a scene fade-in, or another trigger's release).
    // setAmbientVolume alone does not stop _rampAmbient, so without this the
    // ramp's next step would undo the duck ~30 ms later.
    _currentRampId++;
    audio.setAmbientVolume((controller.ambientVolume / 100.0) * _ambientDuckFactor);

    var released = false;
    void release() {
      if (released) return;
      released = true;
      if (gen != _duckGeneration) return;
      _activeDucks--;
      if (_activeDucks == 0) spotify.duckEnd();
      if (_activeDucks > 0) return; // another trigger still holding the duck
      if (_disposed) return;
      // Re-read rather than using a value captured at fire time: the scene may
      // have changed under us, or the slider may have moved. Either way the bed
      // belongs at whatever level is current now.
      // If the scene we landed in has no bed of its own, the ambient player is
      // still looping the *previous* scene's bed at zero — lifting the duck
      // would bring it back. Leave it silent.
      final scene = controller.scene;
      if (scene.ambientId == null) {
        audio.setAmbientVolume(0);
        return;
      }
      final current = controller.ambientVolume / 100.0;
      _rampAmbient(current * _ambientDuckFactor, current, steps: 12, stepMs: 35);
    }

    player.onPlayerComplete.first.then((_) => release());

    // Safety net: the 6 trigger players are recycled in a ring, and
    // AudioEngine.playTrigger calls stop() on reuse. stop() does NOT emit
    // onPlayerComplete, so without this the duck would never lift.
    final fallbackMs = (assetDurationMs > 0 ? assetDurationMs : 5000) + 750;
    Future.delayed(Duration(milliseconds: fallbackMs), release);
  }

  void _onSceneEntered(int index) {
    final scene = controller.pack.scenes[index];
    if (lightsEnabled) {
      runner.setByRef(scene.goveeRef);
    }
    if (soundEnabled) {
      if (scene.spotify.uri.isNotEmpty) {
        spotify.play(scene.spotify.uri, scene.spotify.startTime);
      }
      _performAmbientTransition(scene);
    }
  }

  Future<void> _performAmbientTransition(SessionScene scene) async {
    // If we're already playing something, do a quick fade out or just stop
    // To minimize lag, we just stop the old and start the new instantly.
    if (scene.ambientId != null) {
      final asset = controller.pack.audioManifest[scene.ambientId];
      if (asset != null) {
        final path = '${controller.pack.directoryPath}/${asset.file}';
        await audio.playAmbient(path, 0.0);
        // If a trigger from the outgoing scene is still ringing out, fade in to
        // the ducked level; its release will lift the bed the rest of the way.
        final full = scene.ambientVolume / 100.0;
        final ceiling = _activeDucks > 0 ? full * _ambientDuckFactor : full;
        _rampAmbient(0.0, ceiling);
      }
    } else {
      // Cancel any fade still stepping, or it will keep raising the volume of
      // the outgoing scene's bed after the cut.
      _currentRampId++;
      audio.setAmbientVolume(0);
    }
  }

  void _onTriggerFired(int index) async {
    if (index < 0 || index >= controller.scene.triggers.length) return;
    final t = controller.scene.triggers[index];

    if (t.soundId.isEmpty) {
      if (t.flashRef != null && lightsEnabled) {
        runner.flash(t.flashRef);
      }
      return;
    }

    if (t.flashRef != null && lightsEnabled) {
      Future.delayed(const Duration(milliseconds: 550), () {
        if (!_disposed && lightsEnabled) {
          runner.flash(t.flashRef);
        }
      });
    }

    if (!soundEnabled) return;

    final asset = controller.pack.audioManifest[t.soundId];
    if (asset == null) return;
    final path = '${controller.pack.directoryPath}/${asset.file}';

    try {
      final player = await audio.playTrigger(path);
      _duckAmbientFor(player, asset.durationMs);
    } catch (e) {
      debugPrint('Playback error: $e');
    }
  }

  Future<void> _onStoppedAll() async {
    if (lightsEnabled) {
      runner.stop();
    }
    if (soundEnabled) {
      _currentRampId++;
      audio.pauseAmbient();
      audio.stopTriggers();
      _duckGeneration++;
      if (_activeDucks > 0) {
        _activeDucks = 0;
        await spotify.duckEnd();
      }
      spotify.pause();
    }
  }

  Future<void> _onResumedAll() async {
    final scene = controller.scene;
    if (lightsEnabled) {
      runner.setByRef(scene.goveeRef);
    }
    if (soundEnabled) {
      if (scene.ambientId != null) {
        await audio.setAmbientVolume(0);
        await audio.resumeAmbient();
        _rampAmbient(0.0, controller.ambientVolume / 100.0);
      }
      if (scene.spotify.uri.isNotEmpty) {
        spotify.resume();
      }
    }
  }

  void _onSpotifyPauseToggled(bool paused) {
    if (!soundEnabled) return;
    if (paused) {
      spotify.pause();
    } else {
      spotify.resume();
    }
  }

  void _onSpotifySeekRelative(int deltaMs) {
    if (!soundEnabled) return;
    spotify.seekRelative(deltaMs);
  }

  void _onSpotifySkipped() {
    if (!soundEnabled) return;
    spotify.skip();
  }

  void _onAmbientVolumeChanged(double percent) {
    if (!soundEnabled) return;
    audio.setAmbientVolume(percent / 100.0);
  }

  void _onTriggerVolumeChanged(double percent) {
    if (!soundEnabled) return;
    audio.setTriggerVolume(percent / 100.0);
  }

  void onAppResumed() {
    if (soundEnabled) {
      spotify.connect();
    }
    if (lightsEnabled) {
      // Re-trigger the current scene animation to wake up the timer/engine
      runner.setByRef(controller.scene.goveeRef);
    }
  }

  void dispose() {
    _disposed = true;
    _subscription.cancel();
    spotify.pause();
    runner.dispose();
    audio.dispose();
  }
}
