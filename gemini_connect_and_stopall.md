# Task: Desktop "Connect Spotify" row, and a Stop-all / Resume button on the session screen

Do not touch `android/`. Do not commit. Do not install the APK on any device. Android Spotify behaviour must not change.

---

## Part 1 — Desktop Spotify: explicit one-time connect (`lib/spotify_service.dart` + `lib/main.dart`)

The desktop app currently opens a browser login by itself: at startup (`connect()`) and whenever `play()` finds no token. Replace that with an explicit button.

### 1a. Service API
Add these to the abstract `SpotifyService`:
```dart
/// null = unknown / not applicable, true = logged in, false = needs login.
ValueNotifier<bool?> get connected;
/// true while a browser login is waiting for approval.
ValueNotifier<bool> get loggingIn;
/// Starts the browser login. Returns true if tokens were saved.
Future<bool> login();
```

**AndroidSpotifyService:**
- `connected` is a `ValueNotifier<bool?>(null)` that never changes.
- `loggingIn` is `ValueNotifier(false)`.
- `login()` returns `false` and does nothing. Nothing else changes.

**DesktopSpotifyService:**
- `connect()` must NOT start the browser login any more. It only reads the token file and sets `connected.value = (refresh token present)`.
- `play()` with no valid token must NOT start the login. It logs `SpotifyService: not connected — press "Connect Spotify" in the menu` and returns. Remove any other automatic call to `_startAuth()` elsewhere.
- `login()`:
  - Calls `_startAuth()`, which now returns `Future<bool>`: true when `_exchangeCode` saved the tokens.
  - Sets `loggingIn.value = true` for the duration of the flow and false in `finally`.
  - On success sets `connected.value = true`.
  - If a login is already running, it returns false immediately.
- When a token refresh fails with HTTP 400 or 401 (revoked or invalid refresh token):
  - Delete the token file and set `connected.value = false`.
  - Log `SpotifyService: saved login is no longer valid — reconnect`.
  - Network errors or timeouts must NOT clear the tokens.
- `_writeTokens` success sets `connected.value = true`.

### 1b. Menu row (`TheaterScreen`, desktop only)
- In `TheaterScreen`'s build, add a Spotify status row directly under `_buildHeader()`. Show it only when `!Platform.isAndroid`. Put it in its own method `_buildSpotifyRow()`.
- The row listens to both notifiers (`ValueListenableBuilder`, nested or via `Listenable.merge` + `AnimatedBuilder`). Styling matches the existing dark UI, with small grey text like the header:
  - **`loggingIn` is true:** a small `CircularProgressIndicator` (size 14), plus the text `Waiting for approval in browser…`.
  - **`connected` is true:** `Icons.check_circle` in green (`Colors.greenAccent`, size 16), the text `Spotify connected`, and a `TextButton('Reconnect')` that calls `_loginSpotify()`.
  - **Otherwise:** `Icons.music_off` in grey, the text `Spotify not connected`, and a `FilledButton.tonal('Connect Spotify')` that calls `_loginSpotify()`.
- `_loginSpotify()` awaits `_spotify.login()`. On `false`, if still mounted, it shows a SnackBar: `Spotify login failed — see the terminal log`.
- The existing `initState` call to `_connectSpotify()` stays, because it now only loads the saved status.

---

## Part 2 — Stop-all / Resume on `SessionPerformanceScreen` (`lib/main.dart`, both platforms)

One button that stops everything, then brings the scene back on the second tap. It replaces the pause button removed in commit 1584f10, now also stopping triggers.

### 2a. AudioEngine
Add a method that stops every trigger player without touching the ambient player:
```dart
Future<void> stopTriggers() async {
  for (final p in _triggerPlayers) { await p.stop(); }
}
```

### 2b. Ducking must survive a forced stop
Stopping trigger players does not fire `onPlayerComplete`, so each pending `release()` would only fire from its fallback timer, later.
- Add `int _duckGeneration = 0;`.
- In `_duckAmbientFor`, capture `final gen = _duckGeneration;`. At the very top of `release()`, after the `released` guard, add `if (gen != _duckGeneration) return;`.
- Everything else in `_duckAmbientFor` stays unchanged.

### 2c. State and toggle
- Add `bool _isStopped = false;`.
- `Future<void> _toggleStopAll() async`:
  - Call `HapticFeedback.mediumImpact();`.
  - **When stopping:**
    1. `setState(() { _isStopped = true; _spotifyPaused = true; })`.
    2. `_runner.stop();` (lights off).
    3. `_currentRampId++;` (cancel any ambient fade), then `_audio.pauseAmbient();`.
    4. `_audio.stopTriggers();`
    5. Dispose every controller in `_activeTriggers`, then clear the map inside `setState`.
    6. Release the duck: `_duckGeneration++;`. If `_activeDucks > 0`: set `_activeDucks = 0;` and `await _spotify.duckEnd();`. Await it so the volume restore reaches Spotify before the pause.
    7. `_spotify.pause();`
  - **When resuming:**
    1. `final scene = widget.pack.scenes[_currentIndex];`
    2. `setState(() => _isStopped = false);`
    3. `_runner.setByRef(scene.goveeRef);`
    4. If `scene.ambientId != null`: `await _audio.setAmbientVolume(0); await _audio.resumeAmbient(); _rampAmbient(0.0, _ambientVol / 100.0);`
    5. If `scene.spotify.uri.isNotEmpty`: `_spotify.resume(); setState(() => _spotifyPaused = false);`
    6. Stopped triggers are not replayed.
- In `_enterScene`, add `_isStopped = false;` inside its existing `setState`, because moving to another scene restarts everything anyway.
- Triggers can still be fired while stopped. Do not block them.

### 2d. Button
- Put it at the top of the screen, between the scene nav `Padding`/`Row` and the `const Divider(color: Colors.white12)` below it. This is where the old pause button was:
```dart
Center(
  child: IconButton(
    icon: Icon(_isStopped ? Icons.play_arrow : Icons.stop, size: 32),
    color: _isStopped ? const Color(0xFF63B8DE) : Colors.white54,
    tooltip: _isStopped ? 'Resume scene' : 'Stop everything',
    onPressed: _toggleStopAll,
  ),
),
```
- **Desktop keyboard:** in the same `CallbackShortcuts` bindings as the Escape key (added in the previous task), bind `const SingleActivator(LogicalKeyboardKey.space)` to `_toggleStopAll`.
- Keep the Spotify controls in the bottom bar unchanged.

---

## Verify
1. `flutter analyze`: no new issues (the 3 pre-existing ones are fine).
2. `flutter build linux --dart-define=SPOTIFY_CLIENT_ID=ca8e9bd0cc234c3d9e460224022db37f`: must succeed.
3. `flutter build apk --debug`: must succeed. Do not install it.

Report the output of all three.
