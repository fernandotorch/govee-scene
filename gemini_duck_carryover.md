# Task: Carry the ambient duck across scene changes (replaces the generation counter)

**What is wrong.** `gemini_duck_generation.md` made a scene change *end* the duck: `_enterScene`
zeroes `_activeDucks` and the pending release is discarded. So cutting to a new scene while a
trigger is still audible brings the new bed in at full level immediately — the bed audibly jumps
up mid-trigger.

**Correct behaviour.** A scene change re-targets the bed to the new scene's level but keeps it
ducked for as long as any trigger is still playing. The last trigger to finish lifts the duck, to
whatever the *current* scene's level is.

This makes the generation counter unnecessary: once the release re-reads `_ambientVol`, a release
that outlives its scene already does the right thing. Remove it.

**Second bug, fixed here too.** `_duckAmbientFor` calls `setAmbientVolume` directly, which does
not cancel an in-flight `_rampAmbient`. A trigger fired during a scene fade-in gets un-ducked by
the fade's next step ~30 ms later. Bumping `_currentRampId` cancels the ramp.

One file: `lib/main.dart`. Four edits. No other file.

---

## Edit 1 — delete the generation counter

Find and delete these four lines (keep `_activeDucks` and `_ambientDuckFactor`):

```dart
  // Bumped on every scene change. A duck release carrying an older generation
  // belongs to a scene that is no longer on stage, so it is discarded instead of
  // fighting the new scene's fade-in.
  int _sceneGeneration = 0;
```

## Edit 2 — replace `_duckAmbientFor`

Replace the whole method with:

```dart
  void _duckAmbientFor(AudioPlayer player, int assetDurationMs) {
    _activeDucks++;
    // Cancel any ramp in flight (a scene fade-in, or another trigger's release).
    // setAmbientVolume alone does not stop _rampAmbient, so without this the
    // ramp's next step would undo the duck ~30 ms later.
    _currentRampId++;
    _audio.setAmbientVolume((_ambientVol / 100.0) * _ambientDuckFactor);

    var released = false;
    void release() {
      if (released) return;
      released = true;
      _activeDucks--;
      if (_activeDucks > 0) return; // another trigger still holding the duck
      if (!mounted) return;
      // Re-read rather than using a value captured at fire time: the scene may
      // have changed under us, or the slider may have moved. Either way the bed
      // belongs at whatever level is current now.
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

## Edit 3 — stop resetting the duck in `_enterScene`

In `_enterScene`, find:

```dart
    _isPaused = false;
    // Invalidate any duck still pending from the outgoing scene, and clear the
    // counter so the new scene starts with the bed unducked.
    _sceneGeneration++;
    _activeDucks = 0;
    final scene = widget.pack.scenes[index];
```

Replace with:

```dart
    _isPaused = false;
    // _activeDucks deliberately survives the scene change: a trigger that is
    // still playing must keep the new scene's bed ducked until it finishes.
    final scene = widget.pack.scenes[index];
```

## Edit 4 — bring the new bed in ducked when a trigger is still playing

In `_performAmbientTransition`, find:

```dart
        final path = '${widget.pack.directoryPath}/${asset.file}';
        await _audio.playAmbient(path, 0.0);
        _rampAmbient(0.0, scene.ambientVolume / 100.0);
```

Replace with:

```dart
        final path = '${widget.pack.directoryPath}/${asset.file}';
        await _audio.playAmbient(path, 0.0);
        // If a trigger from the outgoing scene is still ringing out, fade in to
        // the ducked level; its release will lift the bed the rest of the way.
        final full = scene.ambientVolume / 100.0;
        final ceiling = _activeDucks > 0 ? full * _ambientDuckFactor : full;
        _rampAmbient(0.0, ceiling);
```

Leave the `else { _audio.setAmbientVolume(0); }` branch exactly as it is.

---

## What must NOT change

- `_rampAmbient` itself, and its `steps`/`stepMs` defaults.
- `_ambientDuckFactor` (0.35) and the fallback timer arithmetic.
- The `AudioEngine` constructor and its two AudioContexts.
- Anything Spotify-related, in Dart or Kotlin. In particular do not touch or delay the
  `spotifyPlay` call in `_enterScene`.

## How to sanity-check after building

1. Fire a trigger, let it finish. Bed drops, then ramps back to the same level. Unchanged.
2. Fire a long trigger, cut to another scene while it is still audible. The new bed must fade in
   *quiet* and only rise to its full level once the trigger finishes. No jump at the cut.
3. Cut to a new scene with no trigger playing. Bed fades in at full level as before.
4. Fire a trigger immediately after a scene cut, while the new bed is still fading in. The bed
   must stay ducked — it must not continue climbing to full mid-trigger.
5. Two overlapping triggers, cut scenes between them. Bed stays down until the later one ends.
