# Task: Desktop Spotify — play on an open but idle player (NO_ACTIVE_DEVICE fallback)

Problem: `PUT /v1/me/player/play` returns `404 NO_ACTIVE_DEVICE` when no Spotify client is currently active, even though the web player or the desktop app is open on this PC. The Web API accepts `?device_id=<id>` on `/me/player/play`, and that plays on an open but idle device too.

Change `DesktopSpotifyService` in `lib/spotify_service.dart` only. Do not touch `android/` or `main.dart`. Do not commit. Do not install the APK.

1. Add a field `String? _deviceId;`, which remembers the device we last picked.
2. Add a helper `Future<String?> _pickDevice(String token)`:
   - Call `GET https://api.spotify.com/v1/me/player/devices` through the existing `_sendRequest`.
   - Parse `devices[]` and ignore any with `is_restricted == true`.
   - Choose in this order:
     1. the one with `id == _deviceId`
     2. one with `is_active == true`
     3. the first with `type == "Computer"` (this covers the web player and the desktop app)
     4. the first device
   - Store the choice in `_deviceId` and log `SpotifyService: using device "<name>" (<type>)`.
   - If the list is empty or the call fails, log `SpotifyService: no Spotify player is open — open Spotify (web player or desktop app) on this PC` and return null.
3. In `play()`: if the PUT returns 404 and the body contains `NO_ACTIVE_DEVICE`, call `_pickDevice`. If it returns an id, retry the same PUT once, with `?device_id=<Uri.encodeQueryComponent(id)>` appended to the URL. Then continue with the existing success path (the "play ok" log and the delayed seek) based on the retry's response.
4. Do the same once-only fallback in `resume()`. `resume()` must return whatever `_sendRequest` gives back, so check how that code is shaped today.
5. Put the retry logic in one shared private helper, so it is not duplicated between `play()` and `resume()`.
6. Everything else stays as it is: error swallowing, 10 s timeouts, and no throwing to callers.

## Verify
1. `flutter analyze`: no new issues.
2. `flutter build linux --dart-define=SPOTIFY_CLIENT_ID=ca8e9bd0cc234c3d9e460224022db37f`: must succeed.
