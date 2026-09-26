# Task: Let the user cancel or retry a desktop Spotify login

Problem: if Spotify shows an error page (for example a redirect URI mismatch), the browser never calls back. `DesktopSpotifyService` then waits the full 3-minute timeout. The menu row shows "Waiting for approval in browser…" with no way out, so the user cannot retry.

Do not touch `android/`. Do not commit. Do not install the APK.

## `lib/spotify_service.dart`
1. Add `Future<void> cancelLogin();` to the abstract `SpotifyService`. `AndroidSpotifyService` implements it as a no-op.
2. In `DesktopSpotifyService`:
   - Store the auth server in a field `HttpServer? _authServer` (assign it right after the successful bind; set it back to null in the `finally`).
   - `cancelLogin()`: if `_authServer` is not null, log `SpotifyService: login cancelled`, then `await _authServer!.close(force: true)`.
     - Closing the server ends the `await for` loop, so the existing `finally` resets `_isAuthenticating`, `_authServer` and the timer, and `login()` resets `loggingIn` and returns false.
     - Check that `_startAuth` really returns false and runs its `finally` when the server is closed from outside. If it does not, fix it.
   - `login()`: if a login is already running, first `await cancelLogin()`, then wait until `_isAuthenticating` is false. Poll every 50 ms, for at most 2 s. Then start a fresh flow. Pressing Connect again always gives a new browser tab.
   - Lower the auth timeout from 3 minutes to 2 minutes, and update the timeout log text to match.

## `lib/main.dart` — `_buildSpotifyRow()`
- In the `loggingIn` state, add a `TextButton('Cancel')` after the "Waiting for approval in browser…" text. It calls `_spotify.cancelLogin()` (compact visual density, like the Reconnect button).
- `_loginSpotify()` must NOT show the "Spotify login failed" SnackBar when the user cancelled.
  - Add a `bool _loginCancelled` flag in the State class.
  - Set it in the Cancel handler; reset it at the start of `_loginSpotify()`.
  - Skip the SnackBar when it is set.

## Verify
1. `flutter analyze`: no new issues.
2. `flutter build linux --dart-define=SPOTIFY_CLIENT_ID=ca8e9bd0cc234c3d9e460224022db37f`: must succeed.

Do not build the APK for this task.
