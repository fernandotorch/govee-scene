# Task: Do not un-duck into a scene that has no ambient bed

**Bug.** `_performAmbientTransition`'s `else` branch (scene with `ambientId == null`) calls
`_audio.setAmbientVolume(0)` but does not stop the ambient player — the previous scene's bed keeps
looping silently. A duck release that lands after such a cut ramps that silent bed back up to
`_ambientVol / 100`, so the outgoing scene's ambience returns in a scene that is meant to have
none. Blackout Eve has two such scenes ("Meeting Roland", "Chase").

**Second, related.** That same `else` branch does not cancel an in-flight `_rampAmbient`, so a
fade-in from the outgoing scene keeps stepping the volume up after the cut.

One file: `lib/main.dart`. Two edits. No other file.

---

## Edit 1 — release must respect a scene with no bed

In `_duckAmbientFor`, inside `release()`, find:

```dart
      // Re-read rather than using a value captured at fire time: the scene may
      // have changed under us, or the slider may have moved. Either way the bed
      // belongs at whatever level is current now.
      final current = _ambientVol / 100.0;
      _rampAmbient(current * _ambientDuckFactor, current, steps: 12, stepMs: 35);
```

Replace with:

```dart
      // Re-read rather than using a value captured at fire time: the scene may
      // have changed under us, or the slider may have moved. Either way the bed
      // belongs at whatever level is current now.
      // If the scene we landed in has no bed of its own, the ambient player is
      // still looping the *previous* scene's bed at zero — lifting the duck
      // would bring it back. Leave it silent.
      final scene = widget.pack.scenes[_currentIndex];
      if (scene.ambientId == null) {
        _audio.setAmbientVolume(0);
        return;
      }
      final current = _ambientVol / 100.0;
      _rampAmbient(current * _ambientDuckFactor, current, steps: 12, stepMs: 35);
```

## Edit 2 — cancel any in-flight ramp when cutting to a bedless scene

In `_performAmbientTransition`, find the `else` branch:

```dart
    } else {
      _audio.setAmbientVolume(0);
    }
```

Replace with:

```dart
    } else {
      // Cancel any fade still stepping, or it will keep raising the volume of
      // the outgoing scene's bed after the cut.
      _currentRampId++;
      _audio.setAmbientVolume(0);
    }
```

---

## What must NOT change

- Everything else in `_duckAmbientFor`, including `_activeDucks` bookkeeping, the `released`
  guard, the `_currentRampId++` at the top, and the fallback timer.
- The `if (scene.ambientId != null)` branch of `_performAmbientTransition`, including the
  `_activeDucks > 0` ceiling logic.
- `_rampAmbient`, `_ambientDuckFactor`, the `AudioEngine` constructor, anything Spotify-related.

## How to sanity-check after building

1. Fire a trigger, cut to a scene with no ambient (Blackout Eve: "Meeting Roland" or "Chase")
   while the trigger is still audible. When the trigger ends, the bed must stay silent — the
   previous scene's ambience must not creep back in.
2. From that bedless scene, cut to a scene that does have a bed. It fades in normally at full.
3. Re-check: long trigger + cut to a scene that has a bed — new bed fades in ducked, rises when
   the trigger ends.
