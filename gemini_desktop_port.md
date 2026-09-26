# Task: Make the app build and run on Linux desktop, with Android behaviour unchanged

Goal: `flutter run -d linux` gives the same app as on the phone: lights, ambient bed, triggers, ducking and Spotify.
**Hard constraint: the Android build must behave exactly as it does today.** Do not edit `MainActivity.kt`. Do not change any Android code path.

---

## Part 1 — Spotify service abstraction

Create `lib/spotify_service.dart`.

```dart
abstract class SpotifyService {
  factory SpotifyService.create() =>
      Platform.isAndroid ? AndroidSpotifyService() : DesktopSpotifyService();

  Future<void> connect();
  Future<void> refresh();
  Future<void> disconnect();
  Future<void> play(String uri, int startTimeSeconds);
  Future<void> pause();
  Future<void> resume();
  Future<void> skip();
  Future<void> seekRelative(int deltaMs);

  /// Called when the first trigger starts ducking (0 -> 1 active ducks).
  Future<void> duckStart();
  /// Called when the last trigger releases the duck (1 -> 0 active ducks).
  Future<void> duckEnd();
}
```

### 1a. AndroidSpotifyService
A thin wrapper over the existing channel `MethodChannel('com.feru.govee_scene/wifi')`. It uses the same method names and arguments that `main.dart` sends today:
- `connect` -> `spotifyConnect`
- `refresh` -> `spotifyRefresh`
- `disconnect` -> `spotifyDisconnect`
- `play` -> `spotifyPlay` with `{'uri': uri, 'startTime': startTimeSeconds}`
- `pause` -> `spotifyPause`
- `resume` -> `spotifyResume`
- `skip` -> `spotifySkip`
- `seekRelative` -> `spotifySeekRelative` with `deltaMs`

Every call swallows errors (`.catchError((_) {})`), as today.
`duckStart` / `duckEnd` do nothing on Android. The trigger players' audio focus (`gainTransientMayDuck`) already makes Android duck Spotify.

### 1b. DesktopSpotifyService
Pure Dart, using only the Spotify Web API. Use `dart:io` `HttpClient` for HTTP. Add the `crypto` package to pubspec for SHA-256. Port the logic of `MainActivity.kt` as follows.

- **Client ID:** `const String.fromEnvironment('SPOTIFY_CLIENT_ID')`. If it is empty, log once and make every method a no-op.
- **Redirect URI:** `http://127.0.0.1:8898/callback`. Spotify requires the loopback IP literal, not `localhost`.
- **Scopes:** `user-modify-playback-state user-read-playback-state`. The second one is needed for `GET /me/player`.
- **PKCE:**
  - The verifier is 96 bytes from `Random.secure()`, base64url-encoded with no padding, truncated to 128 chars.
  - The challenge is the base64url encoding (no padding) of the verifier's SHA-256.
  - Same as `generateCodeVerifier` / `generateCodeChallenge` in `MainActivity.kt`.
- **Auth flow** (`_startAuth`):
  - Bind an `HttpServer` on `127.0.0.1:8898`.
  - Open the authorize URL in the browser with `Process.run('xdg-open', [url])`.
  - Wait for `GET /callback?code=...`. Answer with a small HTML page saying "Spotify connected — you can close this tab". Close the server.
  - Exchange the code at `https://accounts.spotify.com/api/token` with the same form body as `exchangeSpotifyCode`.
  - Guard with a flag so only one auth flow runs at a time.
  - Time out after 3 minutes and close the server.
- **Token storage:** JSON file `spotify_tokens.json` in `getApplicationSupportDirectory()`. It holds `access_token`, `refresh_token` and `expires_at` (epoch ms).
- **`_validToken()`:** returns the stored token, or refreshes it first if it expires within 60 s. Port `getValidToken` / `refreshSpotifyToken`: keep the old refresh token if the response has none.
- **`connect()`:** if there is no stored refresh token, start the auth flow. Otherwise do nothing.
- **`refresh()`:** force a token refresh.
- **`disconnect()`:** does nothing.
- **`play(uri, startTimeSeconds)`:**
  - Port `toSpotifyUri`.
  - `PUT https://api.spotify.com/v1/me/player/play`. The body is `{"uris":[uri]}` if the URI contains `:track:`, otherwise `{"context_uri":uri}`.
  - On a 2xx response with `startTimeSeconds > 0`: wait 800 ms, then `PUT /me/player/seek?position_ms=<startTimeSeconds*1000>`.
  - If there is no valid token, start the auth flow and return.
- **`pause()`:** `PUT /me/player/pause`.
- **`resume()`:** `PUT /me/player/play` with no body.
- **`skip()`:** `POST /me/player/next`.
- **`seekRelative(deltaMs)`:**
  - `GET /me/player` and read `progress_ms`.
  - Then `PUT /me/player/seek?position_ms=<max(0, progress+delta)>`.
- **`duckStart()`:**
  - `GET /me/player` and read `device.volume_percent`. Store it as `_preDuckVolume`.
  - Then `PUT /me/player/volume?volume_percent=<round(_preDuckVolume * _spotifyDuckFactor)>`, with `static const double _spotifyDuckFactor = 0.3;`.
  - If the GET fails, skip the duck and leave `_preDuckVolume` null.
- **`duckEnd()`:** if `_preDuckVolume` is not null, `PUT /me/player/volume?volume_percent=<_preDuckVolume>`, then set it to null.
- All HTTP errors are caught and ignored. A Spotify failure must never break the session.
- Set a 10 s timeout on every request.

---

## Part 2 — Use the service in `lib/main.dart`

- Replace **every** `_wifiChannel.invokeMethod('spotify...')` / `invokeMethod("spotify...")` call with the matching `SpotifyService` call. Current call sites are around lines 1403, 1407, 1413, 1999, 2096, 2182, 2189, 2191, 2197 and 2329. Grep for `spotify` to catch them all.
- Each screen that uses Spotify holds `final SpotifyService _spotify = SpotifyService.create();`. A single top-level instance is also fine. Keep the behaviour the same.
- Keep `_wifiChannel` for `getHotspotIp`, `acquireMulticastLock` and `releaseMulticastLock`. Those calls are already in try/catch, so on Linux they fail harmlessly and discovery falls through to `_multicastDiscover()`. Do not change them.
- **Ducking hook** in `_duckAmbientFor`:
  - Right after `_activeDucks++`: if `_activeDucks == 1`, call `_spotify.duckStart()` (unawaited).
  - In `release()`: right after `_activeDucks--` and **before** the `if (_activeDucks > 0) return;` line, add `if (_activeDucks == 0) _spotify.duckEnd();` (unawaited).
  - Do not change anything else in the ducking logic.

---

## Part 3 — Platform-safe storage and audio context

- `getExternalStorageDirectory()` is Android-only and throws on Linux. Add one helper:
  ```dart
  Future<Directory> packStorageDir() async {
    if (Platform.isAndroid) return (await getExternalStorageDirectory())!;
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/sessions');
    await dir.create(recursive: true);
    return dir;
  }
  ```
  Replace every `getExternalStorageDirectory()` call (around lines 1334, 1436 and 1820) with `packStorageDir()`. Keep the surrounding null handling valid.
- In `AudioEngine()`, only call `setAudioContext(...)` when `Platform.isAndroid || Platform.isIOS`. The `AudioContext` objects themselves stay as they are.

---

## Part 4 — Verify

1. `flutter analyze`: no new errors.
2. `flutter build apk --debug`: must succeed. **Do not install it.** No `adb install`, no `flutter run` on a device.
3. `flutter build linux --dart-define=SPOTIFY_CLIENT_ID=ca8e9bd0cc234c3d9e460224022db37f`: must succeed. If it fails only because system packages are missing (ninja, GTK, GStreamer), report that and stop. Do not try to install packages.

Do not commit. Do not touch `android/`, `ios/` or `macos/`. Do not delete any `gemini_*.md` files.
