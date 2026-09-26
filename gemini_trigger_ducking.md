# Task: Duck the music and ambient bed while a trigger plays

**Problem:** triggers are inaudible under Spotify + the ambient bed. The trigger slider is
already at unity gain (`AudioPlayer.setVolume` clamps at 1.0) and the trigger files already
peak at ~0 dBFS, so there is no headroom left to make triggers louder. The separation has to
come from ducking the other two sources for the duration of the trigger.

Two files to edit: `lib/main.dart` only. No Kotlin changes. No pubspec changes.

---

## Part 1 — Give the trigger players their own AudioContext with ducking focus

In `class AudioEngine`, find the constructor:

```dart
  AudioEngine() {
    _ambientPlayer.setReleaseMode(ReleaseMode.loop);
    final audioContext = AudioContext(
      android: AudioContextAndroid(
        isSpeakerphoneOn: false,
        stayAwake: false,
        contentType: AndroidContentType.music,
        usageType: AndroidUsageType.media,
        audioFocus: AndroidAudioFocus.none,
      ),
    );
    _ambientPlayer.setAudioContext(audioContext);
    for (final p in _triggerPlayers) {
      p.setAudioContext(audioContext);
    }
  }
```

Replace the whole constructor body with:

```dart
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

    _ambientPlayer.setAudioContext(ambientContext);
    for (final p in _triggerPlayers) {
      p.setAudioContext(triggerContext);
    }
  }
```

Do not change `contentType` — leave it `music` on both. Only `audioFocus` differs.

---

## Part 2 — Duck the ambient bed in Dart

Android's focus ducking only affects *other apps* (Spotify). Our own ambient player has to be
ducked explicitly.

### 2a. Make the ambient ramp duration configurable

Find `_rampAmbient` in `_SessionPerformanceScreenState`:

```dart
  Future<void> _rampAmbient(double from, double to) async {
    final rampId = ++_currentRampId;
    const steps = 6; const stepMs = 30; // Faster steps
    for (int i = 1; i <= steps; i++) {
      if (rampId != _currentRampId) return;
      final v = from + (to - from) * i / steps;
      _audio.setAmbientVolume(v);
      if (i < steps) await Future.delayed(const Duration(milliseconds: stepMs));
    }
  }
```

Replace with:

```dart
  Future<void> _rampAmbient(double from, double to, {int steps = 6, int stepMs = 30}) async {
    final rampId = ++_currentRampId;
    for (int i = 1; i <= steps; i++) {
      if (rampId != _currentRampId) return;
      final v = from + (to - from) * i / steps;
      _audio.setAmbientVolume(v);
      if (i < steps) await Future.delayed(Duration(milliseconds: stepMs));
    }
  }
```

Existing callers keep working unchanged.

### 2b. Add the duck state and helper

Directly after the `_rampAmbient` method, add:

```dart
  // How far the bed drops while a trigger is playing. 0.35 = -9 dB.
  static const double _ambientDuckFactor = 0.35;

  // Number of triggers currently holding the duck open.
  int _activeDucks = 0;

  void _duckAmbientFor(AudioPlayer player, int assetDurationMs) {
    final target = _ambientVol / 100.0;
    _activeDucks++;
    // Duck down immediately — a ramp here would soften the very transient we are
    // trying to expose.
    _audio.setAmbientVolume(target * _ambientDuckFactor);

    var released = false;
    void release() {
      if (released) return;
      released = true;
      _activeDucks--;
      if (_activeDucks > 0) return; // another trigger still holding the duck
      if (!mounted) return;
      _rampAmbient(target * _ambientDuckFactor, target, steps: 12, stepMs: 35);
    }

    player.onPlayerComplete.first.then((_) => release());

    // Safety net: the 6 trigger players are recycled in a ring, and
    // AudioEngine.playTrigger calls stop() on reuse. stop() does NOT emit
    // onPlayerComplete, so without this the duck would never lift.
    final fallbackMs = (assetDurationMs > 0 ? assetDurationMs : 5000) + 750;
    Future.delayed(Duration(milliseconds: fallbackMs), release);
  }
```

### 2c. Call it from `_fireTrigger`

In `_fireTrigger`, find:

```dart
      final player = await _audio.playTrigger(path);
```

Add one line immediately after it:

```dart
      final player = await _audio.playTrigger(path);
      _duckAmbientFor(player, asset.durationMs);
```

`asset` is already in scope at that point (`widget.pack.audioManifest[t.soundId]`).

---

## What must NOT change

- `AudioEngine.playTrigger`, `setTriggerVolume`, `_triggerVolume` — the trigger gain path is
  already at unity and must stay there.
- The ambient player's `ReleaseMode.loop` and its `audioFocus: none`.
- The `_ambientVol` / `_triggerVol` slider defaults (50 / 80) — Fernando will tune those by ear
  after hearing the duck.
- Anything Spotify-related in `MainActivity.kt`. The whole point of using audio focus is that it
  needs no Web API volume call.

## How to sanity-check after building

1. Start Spotify playing, enter a scene with an ambient bed.
2. Fire a trigger. Spotify and the bed should both drop for the length of the trigger, then
   come back. The bed's return should be a ~400 ms ramp, not a jump.
3. Fire two triggers overlapping. The bed must stay down until the *second* one finishes, then
   ramp back once.
4. Fire the same trigger 8 times fast (forces the 6-player ring to recycle). The bed must always
   return to level — if it stays ducked, the fallback timer in `_duckAmbientFor` is wrong.
