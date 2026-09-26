# Task: Make the ambient duck scene-aware (follow-up to gemini_trigger_ducking.md)

**Bug being fixed.** `_duckAmbientFor` snapshots the ambient level at fire time and restores to
that snapshot when the trigger ends. If the scene changes while a trigger is still ringing out,
the pending restore (a) targets the *previous* scene's volume and (b) bumps `_currentRampId`,
which cancels the new scene's fade-in. Result: the new bed ends up parked at the old scene's
level. Same class of problem if the ambient slider is moved mid-trigger.

**Fix.** A scene-generation counter. `_enterScene` bumps it; a duck release belonging to an
older generation is discarded silently, leaving the scene's own fade-in untouched. The restore
also re-reads the current ambient level instead of using the snapshot.

One file: `lib/main.dart`. Three edits. No other file.

---

## Edit 1 — add the generation counter

Find this block (it sits just above `_activeDucks`):

```dart
  // How far the bed drops while a trigger is playing. 0.35 = -9 dB.
  static const double _ambientDuckFactor = 0.35;

  // Number of triggers currently holding the duck open.
  int _activeDucks = 0;
```

Replace it with:

```dart
  // How far the bed drops while a trigger is playing. 0.35 = -9 dB.
  static const double _ambientDuckFactor = 0.35;

  // Number of triggers currently holding the duck open.
  int _activeDucks = 0;

  // Bumped on every scene change. A duck release carrying an older generation
  // belongs to a scene that is no longer on stage, so it is discarded instead of
  // fighting the new scene's fade-in.
  int _sceneGeneration = 0;
```

## Edit 2 — make the release generation-aware and re-read the level

Find the whole `_duckAmbientFor` method and replace it with:

```dart
  void _duckAmbientFor(AudioPlayer player, int assetDurationMs) {
    final gen = _sceneGeneration;
    _activeDucks++;
    // Duck down immediately — a ramp here would soften the very transient we are
    // trying to expose.
    _audio.setAmbientVolume((_ambientVol / 100.0) * _ambientDuckFactor);

    var released = false;
    void release() {
      if (released) return;
      released = true;
      // Stale duck: the scene changed under us. _enterScene already reset
      // _activeDucks and owns the bed now, so do not touch the counter or the
      // volume — touching either would cancel the new scene's fade-in.
      if (gen != _sceneGeneration) return;
      _activeDucks--;
      if (_activeDucks > 0) return; // another trigger still holding the duck
      if (!mounted) return;
      // Re-read rather than using a value captured at fire time, so a slider
      // move during the trigger is respected.
      final current = _ambientVol / 100.0;
      _rampAmbient(current * _ambientDuckFactor, current, steps: 12, stepMs: 35);
    }

    player.onPlayerComplete.first.then((_) => release());

    // Safety net: the 6 trigger players are recycled in a ring, and
    // AudioEngine.playTrigger calls stop() on reuse. stop() does NOT emit
    // onPlayerComplete, so without this the duck would never lift.
    final fallbackMs = (assetDurationMs > 0 ? assetDurationMs : 5000) + 750;
    Future.delayed(Duration(milliseconds: fallbackMs), release);
  }
```

## Edit 3 — bump the generation in `_enterScene`

In `_enterScene`, find:

```dart
  void _enterScene(int index) {
    _isPaused = false;
    final scene = widget.pack.scenes[index];
```

Replace with:

```dart
  void _enterScene(int index) {
    _isPaused = false;
    // Invalidate any duck still pending from the outgoing scene, and clear the
    // counter so the new scene starts with the bed unducked.
    _sceneGeneration++;
    _activeDucks = 0;
    final scene = widget.pack.scenes[index];
```

Keep the existing odd indentation of the `void _enterScene(int index) {` line exactly as it is
in the file — do not reformat surrounding code.

---

## What must NOT change

- `_rampAmbient` — it already takes `steps`/`stepMs`; leave it alone.
- `_performAmbientTransition` and its `_rampAmbient(0.0, scene.ambientVolume / 100.0)` call.
- `_ambientDuckFactor`'s value (0.35) and the fallback timer arithmetic.
- The `AudioEngine` constructor and its two AudioContexts.
- Anything Spotify-related, in Dart or Kotlin.

## How to sanity-check after building

1. Fire a trigger, let it finish. Bed drops and ramps back to the same level as before.
2. Fire a long trigger and change scene while it is still audible. The new scene's bed must
   fade in to *its own* volume and stay there — no jump to the previous scene's level, no dip.
3. Fire a trigger and drag the ambient slider while it plays. When the trigger ends the bed
   must settle at the slider's new position, not snap back to the old one.
4. Fire two overlapping triggers in one scene. Bed stays down until the second finishes, then
   ramps back once.
