# Task: Remove Spotify volume slider and revert setSpotifyVolume to AudioManager

Two files to edit: `lib/main.dart` and `android/app/src/main/kotlin/com/feru/govee_scene/MainActivity.kt`

---

## Part 1 — main.dart

### 1a. Remove _spotifyVol state and related code

In `_SessionPerformanceScreenState`, remove the `_spotifyVol` field:
```dart
double _spotifyVol = 50, _ambientVol = 50, _triggerVol = 80;
```
Replace with:
```dart
double _ambientVol = 50, _triggerVol = 80;
```

### 1b. Remove setSpotifyVolume call from _enterScene

In `_enterScene`, find and remove these two lines entirely:
```dart
      await _wifiChannel.invokeMethod('setSpotifyVolume', scene.spotify.volume).catchError((_) {});
      setState(() => _spotifyVol = scene.spotify.volume.toDouble());
```

### 1c. Remove the Spotify slider row from the Live Mixer

In the `build` method, inside the Live Mixer `Column`, find and remove the entire Spotify slider Row (the one with `Icons.music_note`). It looks like this:

```dart
                Row(children: [
                  const Icon(Icons.music_note, size: 18, color: Colors.grey),
                  Expanded(child: Slider(
                    value: _spotifyVol, min: 0, max: 100, activeColor: const Color(0xFF63B8DE),
                    onChanged: (v) {
                      setState(() => _spotifyVol = v);
                      _wifiChannel.invokeMethod('setSpotifyVolume', v.round()).catchError((_) {});
                    },
                  )),
                  Text('${_spotifyVol.round()}%', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 18),
                    color: Colors.grey,
                    onPressed: () => _wifiChannel.invokeMethod('spotifyPlay', scene.spotify.uri).catchError((_) {}),
                  ),
                ]),
```

Remove the entire Row block above. Do not remove the ambient or trigger slider rows.

---

## Part 2 — MainActivity.kt

### 2a. Revert setSpotifyVolume to AudioManager

Find the `"setSpotifyVolume" ->` handler. It currently launches a Thread and calls the Web API. Replace the entire branch with:

```kotlin
"setSpotifyVolume" -> {
    val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
    val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
    val vol = ((call.arguments as Int) / 100.0 * max).toInt().coerceIn(0, max)
    am.setStreamVolume(AudioManager.STREAM_MUSIC, vol, 0)
    result.success(null)
}
```

### 2b. Remove the diagnostic toast from setSpotifyVolume

The handler above is the complete replacement — no Thread, no toast, no Web API call.

---

## What must NOT change
- `spotifyPlay`, `spotifyPause`, `spotifyResume` handlers — leave them as Web API calls
- Ambient slider row (Icons.waves) — leave it
- Trigger slider row (Icons.bolt) — leave it
- All PKCE auth functions — leave them
