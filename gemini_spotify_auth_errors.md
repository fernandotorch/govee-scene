# Task: Make desktop Spotify auth failures visible

File: `lib/spotify_service.dart`, `DesktopSpotifyService` only. Do not touch anything else.

1. In `_startAuth()`:
   - Wrap `HttpServer.bind(InternetAddress.loopbackIPv4, 8898)` in its own try/catch.
   - On a `SocketException`, `debugPrint('SpotifyService: cannot listen on 127.0.0.1:8898 (port in use?) — Spotify login aborted: $e');` and return. The `finally` must still reset `_isAuthenticating`.
   - Change the outer `catch (_) {}` to `catch (e) { debugPrint('SpotifyService: auth flow failed: $e'); }`.
   - When the 3-minute timeout fires, `debugPrint('SpotifyService: login timed out after 3 minutes');`.
2. Make `_exchangeCode` return `Future<bool>`: `true` only when the tokens were written.
   - In the non-2xx branch, `debugPrint` the status code and the response body instead of draining silently.
   - In the catch, `debugPrint` the error.
3. In the `/callback` handler, run the code exchange **before** writing the HTML response:
   - If it succeeds, reply "Spotify connected — you can close this tab".
   - Otherwise reply "Spotify login failed — check the app log" (also shown when `code` is missing, or the query has `error=...`; include that error value in the page and in a `debugPrint`).
3. Leave the other methods' silent error swallowing as it is. Only the auth path gets logging.

Verify:
- `flutter analyze`: no new issues.
- `flutter build linux --dart-define=SPOTIFY_CLIENT_ID=ca8e9bd0cc234c3d9e460224022db37f` must succeed.

Do not build or install the APK. Do not commit. Do not touch `android/`.
