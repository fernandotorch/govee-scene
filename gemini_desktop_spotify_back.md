# Task: Fix desktop Spotify control and add an in-app back button

Two independent fixes. Do not touch `android/`. Do not commit. Do not install the APK on any device.

---

## Part 1 — Desktop Spotify: one shared instance and visible errors (`lib/spotify_service.dart`)

### 1a. Single shared instance
Today `TheaterScreen` and `SessionPerformanceScreen` each call `SpotifyService.create()`, which gives two `DesktopSpotifyService` objects. Each has its own `_isAuthenticating` flag and `_preDuckVolume`. The first starts a login and holds port 8898. When the second finds no token, its own login fails to bind, and nothing is saved.

Change the factory so it always returns one shared instance:
```dart
static SpotifyService? _instance;
factory SpotifyService.create() =>
    _instance ??= (Platform.isAndroid ? AndroidSpotifyService() : DesktopSpotifyService());
```
(Adapt as needed, since a factory on an abstract class can use a static field.) Keep the call sites in `main.dart` unchanged.

### 1b. Log the desktop Web API flow (DesktopSpotifyService only)
Use `debugPrint` with the prefix `SpotifyService:` for all of these:
- **When `_startAuth` begins:** log `opening Spotify login in browser`, followed by the full authorize URL, so the user can paste it manually if `xdg-open` did nothing.
- **When `_exchangeCode` saves tokens:** log `login saved`.
- **When `play()` has no valid token:** log `no token — starting login` before calling `_startAuth()`.
- **For every Web API request** (play, seek, pause, resume, next, GET /me/player, volume):
  - If the response is not 2xx, log the method, path, status code and response body. For example, a 404 `NO_ACTIVE_DEVICE` must show up in the log.
  - Keep swallowing the error afterwards. Nothing must throw to the caller.
  - If there is a shared request helper, put the logging there once.
- **After a successful `play()`:** log `play <uri> ok`.

Android behaviour must not change. `AndroidSpotifyService` stays as it is, apart from being returned by the shared factory.

---

## Part 2 — In-app back button on the session screen (`lib/main.dart`)

`SessionPerformanceScreen` has no AppBar. On the phone, users leave it with the system back gesture, but desktop has no equivalent. Add an explicit exit control that works the same on both platforms:

- In the `build` method, the scene nav `Row` sits inside the `Padding` at the top of the `Column`. Insert an `IconButton` as the first child of that Row:
  - `icon: const Icon(Icons.close, size: 20)`, `color: Colors.white54`, `tooltip: 'Back to menu'`
  - `onPressed: () => Navigator.maybePop(context)`
  - `padding: EdgeInsets.zero`, `constraints: const BoxConstraints()`
  - Follow it with `const SizedBox(width: 8)`.
  - Do NOT use an arrow icon: the prev-scene control right next to it already uses `arrow_back_ios`.
- **Desktop keyboard:** pressing Escape on this screen must do the same `Navigator.maybePop(context)`.
  - Wrap the screen's `Scaffold` in `CallbackShortcuts(bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context)}, child: Focus(autofocus: true, child: <Scaffold>))`.
  - `LogicalKeyboardKey` comes from `package:flutter/services.dart`. Check whether it is already imported.
  - Any existing keyboard handling on this screen must keep working. If it already uses a `Focus`/`KeyboardListener`, add Escape there instead of adding a second focus node.
- Leaving the screen must run the existing `dispose()` exactly as the system back does today, which pauses Spotify and disposes the runner and audio. Do not add a confirmation dialog.
- Do not change any other screen.

---

## Verify
1. `flutter analyze`: no new issues (the 3 pre-existing ones are fine).
2. `flutter build linux --dart-define=SPOTIFY_CLIENT_ID=ca8e9bd0cc234c3d9e460224022db37f`: must succeed.
3. `flutter build apk --debug`: must succeed. Do not install it.

Report the output of all three.
