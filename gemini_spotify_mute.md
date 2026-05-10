# Task: Add Spotify pause/resume button to Live Mixer in lib/main.dart

**File to edit:** `lib/main.dart`

---

## 1. Add _spotifyPaused state field

In `_SessionPerformanceScreenState`, find the state fields line:
```dart
  double _ambientVol = 50, _triggerVol = 80;
```
Replace with:
```dart
  double _ambientVol = 50, _triggerVol = 80;
  bool _spotifyPaused = false;
```

---

## 2. Add _toggleSpotify method

Add this method to `_SessionPerformanceScreenState`, alongside the other methods like `_togglePause` and `_fireTrigger`:

```dart
  void _toggleSpotify() {
    setState(() => _spotifyPaused = !_spotifyPaused);
    if (_spotifyPaused) {
      _wifiChannel.invokeMethod('spotifyPause', null).catchError((_) {});
    } else {
      _wifiChannel.invokeMethod('spotifyResume', null).catchError((_) {});
    }
  }
```

---

## 3. Reset _spotifyPaused on scene entry

In `_enterScene`, find this line:
```dart
      await _wifiChannel.invokeMethod('spotifyPlay', scene.spotify.uri).catchError((_) {});
```
Add `setState(() => _spotifyPaused = false);` immediately after it:
```dart
      await _wifiChannel.invokeMethod('spotifyPlay', scene.spotify.uri).catchError((_) {});
      setState(() => _spotifyPaused = false);
```

---

## 4. Add the Spotify row to the Live Mixer

In the `build` method, inside the Live Mixer `Column`, find the ambient slider row which starts with `Row(children: [` and `const Icon(Icons.waves, ...)`. Add the following new Row BEFORE it (so Spotify row is at the top of the mixer):

```dart
                Row(children: [
                  const Icon(Icons.music_note, size: 18, color: Colors.grey),
                  const Expanded(
                    child: Text('Spotify', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ),
                  IconButton(
                    icon: Icon(
                      _spotifyPaused ? Icons.play_arrow : Icons.pause,
                      size: 20,
                    ),
                    color: _spotifyPaused ? const Color(0xFF63B8DE) : Colors.grey,
                    onPressed: _toggleSpotify,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  const SizedBox(width: 24),
                ]),
```

---

## What must NOT change
- Ambient slider row — leave it
- Trigger slider row — leave it
- `_togglePause` method — leave it
- Everything else — leave it
