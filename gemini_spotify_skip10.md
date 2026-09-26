# Task: Add a "+10 s" button to the scene screen that nudges the Spotify track forward

Fernando wants to skip past slow intros during a session. The button must be pressable
repeatedly — three presses = +30 s.

Two files: `lib/main.dart` and
`android/app/src/main/kotlin/com/feru/govee_scene/MainActivity.kt`.

The App Remote SDK has `PlayerApi.seekToRelativePosition(long)`, which is relative, so repeated
presses accumulate with no position tracking on our side. The Web API has no relative seek, so
the cloud fallback has to read the current position first.

---

## Part 1 — MainActivity.kt

### 1a. Add a GET helper

Next to the existing `webApiPut` / `webApiPost` helpers, add:

```kotlin
    private fun webApiGet(url: String, token: String): java.net.HttpURLConnection {
        val conn = java.net.URL(url).openConnection() as java.net.HttpURLConnection
        conn.requestMethod = "GET"
        conn.connectTimeout = 10000
        conn.readTimeout = 10000
        conn.setRequestProperty("Authorization", "Bearer $token")
        return conn
    }
```

### 1b. Add the method channel handler

Find the `"spotifySkip" ->` branch. Immediately **after** its closing brace, and **before**
`else -> result.notImplemented()`, add:

```kotlin
                    "spotifySeekRelative" -> {
                        val deltaMs = (call.arguments as? Int) ?: 10000
                        val remote = spotifyAppRemote
                        if (remote?.isConnected == true) {
                            remote.playerApi.seekToRelativePosition(deltaMs.toLong())
                            result.success(true)
                        } else {
                            Thread {
                                val token = getValidToken() ?: run { runOnUiThread { result.success(false) }; return@Thread }
                                try {
                                    // The Web API has no relative seek, so read the
                                    // current position and add to it.
                                    val conn = webApiGet("https://api.spotify.com/v1/me/player", token)
                                    val progress = if (conn.responseCode in 200..299) {
                                        val body = conn.inputStream.bufferedReader().use { it.readText() }
                                        org.json.JSONObject(body).optInt("progress_ms", -1)
                                    } else -1
                                    if (progress >= 0) {
                                        val target = (progress + deltaMs).coerceAtLeast(0)
                                        webApiPut("https://api.spotify.com/v1/me/player/seek?position_ms=$target", token).responseCode
                                        runOnUiThread { result.success(true) }
                                    } else {
                                        runOnUiThread { result.success(false) }
                                    }
                                } catch (e: Exception) {
                                    runOnUiThread { result.success(false) }
                                }
                            }.start()
                        }
                    }
```

Do not touch `spotifyPlay`, `spotifyPause`, `spotifyResume`, `spotifySkip`, `setMediaVolume`, or
any of the PKCE auth code.

---

## Part 2 — main.dart

### 2a. Add the skip method

In `_SessionPerformanceScreenState`, next to `_togglePause`, add:

```dart
  static const int _spotifyNudgeMs = 10000;

  void _skipForward() {
    HapticFeedback.lightImpact();
    // seekToRelativePosition is relative, so repeated presses stack: three
    // presses is +30 s. No local position tracking needed.
    _wifiChannel
        .invokeMethod('spotifySeekRelative', _spotifyNudgeMs)
        .catchError((_) {});
  }
```

### 2b. Put the button next to the pause control

Find the centred pause button in `build`:

```dart
            Center(
              child: IconButton(
                icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause, size: 32),
                color: _isPaused ? const Color(0xFF63B8DE) : Colors.white54,
                tooltip: _isPaused ? 'Resume' : 'Pause',
                onPressed: _togglePause,
              ),
            ),
```

Replace with:

```dart
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause, size: 32),
                  color: _isPaused ? const Color(0xFF63B8DE) : Colors.white54,
                  tooltip: _isPaused ? 'Resume' : 'Pause',
                  onPressed: _togglePause,
                ),
                const SizedBox(width: 24),
                IconButton(
                  icon: const Icon(Icons.forward_10, size: 32),
                  color: Colors.white54,
                  tooltip: 'Skip music forward 10 s',
                  onPressed: _skipForward,
                ),
              ],
            ),
```

`HapticFeedback` is already imported and used in `_fireTrigger` — do not add an import for it.

---

## What must NOT change

- Any of the ambient-duck code: `_duckAmbientFor`, `_activeDucks`, `_ambientDuckFactor`,
  `_rampAmbient`, `_performAmbientTransition`, the `AudioEngine` constructor.
- `_togglePause` itself, and the scene navigation controls.
- The trigger grid and `_fireTrigger`.

## How to sanity-check after building

1. Play a scene with Spotify. Press +10 once — the track jumps forward ten seconds and keeps
   playing.
2. Press it three times quickly — it should land ~30 s further in, not 10.
3. Press it near the end of a track. Spotify's own behaviour takes over (it advances to the next
   track); it must not crash or wedge the app.
4. Press it while a trigger is playing. The ambient duck must behave exactly as before.

## Known limitation, do not try to fix

When Spotify is *not* connected via App Remote and the cloud fallback is used, two very fast
presses can both read the same `progress_ms` and land at +10 instead of +20. The App Remote path
(Spotify running on the same phone, the normal case) is unaffected because the SDK seek is truly
relative.
